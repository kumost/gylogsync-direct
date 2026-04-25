// GyroflowBridge.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

import Foundation
import AVFoundation
import CoreImage
import CGyroflowBridge

enum GyroflowError: LocalizedError {
    case contextCreationFailed
    case bridgeError(String)
    case videoError(String)

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            return "Failed to create Gyroflow context"
        case .bridgeError(let msg):
            return msg
        case .videoError(let msg):
            return "Video: \(msg)"
        }
    }
}

class GyroflowProcessor {
    private var context: GFContext?

    init() throws {
        context = gf_context_new()
        guard context != nil else {
            throw GyroflowError.contextCreationFailed
        }
    }

    deinit {
        if let ctx = context {
            gf_context_free(ctx)
        }
    }

    /// Full pipeline: load video, load gyro, sync, export
    func syncAndExport(
        videoPath: String,
        gcsvPath: String,
        outputPath: String,
        lensProfilePath: String? = nil,
        initialOffsetMs: Double = 0,
        searchSizeMs: Double = 500,
        processingHeight: Int = 720,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        progress?(0.05)

        // Step 1: Get video metadata via AVFoundation
        let videoURL = URL(fileURLWithPath: videoPath)
        let asset = AVURLAsset(url: videoURL)

        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw GyroflowError.videoError("No video track found")
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let frameRate = try await videoTrack.load(.nominalFrameRate)

        let width = Int(naturalSize.width)
        let height = Int(naturalSize.height)
        let fps = Double(frameRate)
        let durationMs = CMTimeGetSeconds(duration) * 1000.0
        let frameCount = Int(CMTimeGetSeconds(duration) * fps)

        progress?(0.10)

        // Init video in Rust
        var errorPtr: UnsafeMutablePointer<CChar>? = nil

        var result = gf_init_video(
            context, videoPath,
            UInt32(width), UInt32(height),
            fps, durationMs, UInt32(frameCount),
            &errorPtr
        )
        try checkResult(result, &errorPtr)

        progress?(0.15)

        // Step 2: Load GCSV
        result = gf_load_gyro(context, gcsvPath, &errorPtr)
        try checkResult(result, &errorPtr)

        progress?(0.18)

        // Step 2b: Load lens profile (optional, improves sync accuracy)
        if let lensPath = lensProfilePath {
            result = gf_load_lens_profile(context, lensPath, &errorPtr)
            if result != 0 {
                // Non-fatal: log warning but continue without lens profile
                let msg = errorPtr.map { String(cString: $0) } ?? "unknown"
                print("WARNING: Lens profile load failed: \(msg)")
                if let ptr = errorPtr { gf_free_string(ptr); errorPtr = nil }
            }
        }

        progress?(0.20)

        // Step 3: Start sync
        result = gf_start_sync(context, initialOffsetMs, searchSizeMs, &errorPtr)
        try checkResult(result, &errorPtr)

        progress?(0.25)

        // Step 4: Decode frames with AVFoundation and feed to Rust
        try await decodeAndFeedFrames(
            asset: asset,
            videoTrack: videoTrack,
            processingHeight: processingHeight,
            totalFrames: frameCount,
            progress: { p in
                progress?(0.25 + p * 0.55) // 25% to 80%
            }
        )

        progress?(0.80)

        // Step 5: Finish sync
        result = gf_finish_sync(context, &errorPtr)
        try checkResult(result, &errorPtr)

        progress?(0.90)

        // Step 6: Export
        result = gf_export(context, outputPath, &errorPtr)
        try checkResult(result, &errorPtr)

        progress?(1.0)
    }

    /// Decode video frames using AVFoundation and feed grayscale to Rust
    private func decodeAndFeedFrames(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        processingHeight: Int,
        totalFrames: Int,
        progress: @escaping (Double) -> Void
    ) async throws {
        let naturalSize = try await videoTrack.load(.naturalSize)
        let scale = Double(processingHeight) / Double(naturalSize.height)
        let procWidth = Int(Double(naturalSize.width) * scale)
        let procHeight = processingHeight

        // Set up AVAssetReader
        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: procWidth,
            kCVPixelBufferHeightKey as String: procHeight,
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw GyroflowError.videoError("Cannot start reading: \(reader.error?.localizedDescription ?? "unknown")")
        }

        var frameNo: UInt32 = 0
        // Reusable de-padded Y-plane buffer. Allocated once based on the first
        // pixel buffer's dimensions, then reused for every subsequent frame.
        // Previously this was allocated per-frame (~900KB × 1300+ frames =
        // multi-GB of churn). Capacity is grown if a later frame is larger.
        var compactBuf: [UInt8] = []

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestampUs = Int64(CMTimeGetSeconds(presentationTime) * 1_000_000.0)

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                frameNo += 1
                continue
            }

            let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            guard lockResult == kCVReturnSuccess else {
                frameNo += 1
                continue
            }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let yPlaneRaw = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                frameNo += 1
                continue
            }
            let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

            // Copy Y plane removing stride padding so width == stride.
            // AVFoundation may pad rows (e.g. stride=1024 for width=1005),
            // but gyroflow-core expects contiguous pixels with stride == width.
            let needed = yWidth * yHeight
            if compactBuf.count != needed {
                compactBuf = [UInt8](repeating: 0, count: needed)
            }
            let src = yPlaneRaw.assumingMemoryBound(to: UInt8.self)
            compactBuf.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                for row in 0..<yHeight {
                    memcpy(dstBase + row * yWidth, src + row * yStride, yWidth)
                }
            }
            compactBuf.withUnsafeBufferPointer { buf in
                guard let bufBase = buf.baseAddress else { return }
                gf_feed_frame(
                    context,
                    timestampUs,
                    frameNo,
                    UInt32(yWidth),
                    UInt32(yHeight),
                    UInt32(yWidth),
                    bufBase,
                    UInt32(yWidth * yHeight)
                )
            }

            frameNo += 1
            if frameNo % 10 == 0 {
                progress(Double(frameNo) / Double(max(totalFrames, 1)))
            }
        }

        if reader.status == .failed {
            throw GyroflowError.videoError("Reading failed: \(reader.error?.localizedDescription ?? "unknown")")
        }
    }

    /// Timestamp-based export: skip optical flow, set offset directly
    /// Use when optical flow crashes or video has insufficient motion
    func timestampExport(
        videoPath: String,
        gcsvPath: String,
        outputPath: String,
        lensProfilePath: String? = nil,
        offsetMs: Double = 0,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        progress?(0.10)

        // Get video metadata via AVFoundation
        let videoURL = URL(fileURLWithPath: videoPath)
        let asset = AVURLAsset(url: videoURL)

        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw GyroflowError.videoError("No video track found")
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let frameRate = try await videoTrack.load(.nominalFrameRate)

        let width = Int(naturalSize.width)
        let height = Int(naturalSize.height)
        let fps = Double(frameRate)
        let durationMs = CMTimeGetSeconds(duration) * 1000.0
        let frameCount = Int(CMTimeGetSeconds(duration) * fps)

        progress?(0.30)

        var errorPtr: UnsafeMutablePointer<CChar>? = nil

        // Init video
        var result = gf_init_video(
            context, videoPath,
            UInt32(width), UInt32(height),
            fps, durationMs, UInt32(frameCount),
            &errorPtr
        )
        try checkResult(result, &errorPtr)

        // Load GCSV
        result = gf_load_gyro(context, gcsvPath, &errorPtr)
        try checkResult(result, &errorPtr)

        progress?(0.50)

        // Load lens profile (optional)
        if let lensPath = lensProfilePath {
            result = gf_load_lens_profile(context, lensPath, &errorPtr)
            if result != 0 {
                let msg = errorPtr.map { String(cString: $0) } ?? "unknown"
                print("WARNING: Lens profile load failed: \(msg)")
                if let ptr = errorPtr { gf_free_string(ptr); errorPtr = nil }
            }
        }

        progress?(0.60)

        // Set offset directly (no optical flow)
        result = gf_set_offset(context, offsetMs, &errorPtr)
        try checkResult(result, &errorPtr)

        progress?(0.80)

        // Export
        result = gf_export(context, outputPath, &errorPtr)
        try checkResult(result, &errorPtr)

        progress?(1.0)
    }

    /// Run optical flow sync in a subprocess for crash isolation (SIGSEGV protection).
    ///
    /// `imuOrientationMode`:
    ///   - `"DETECT"` → run gyroflow-core's guess_imu_orientation (~90s extra)
    ///   - 3-letter axis like `"XYZ"` / `"XyZ"` / `"ZYx"` → skip detection, force this value
    ///   - `nil` / empty → use heuristic from gcsv id (fast, no detection)
    ///
    /// Returns the IMU orientation string actually written to the .gyroflow file.
    /// Caller should remember this value across a batch and pass it (as the forced
    /// value) on subsequent clips to avoid the slow detection pass on each clip.
    static func syncInSubprocess(
        videoPath: String,
        gcsvPath: String,
        outputPath: String,
        lensProfilePath: String? = nil,
        initialOffsetMs: Double = 0,
        searchSizeMs: Double = 500,
        imuOrientationMode: String? = nil,
        frameReadoutTimeMs: Double? = nil,
        progress: ((Double) -> Void)? = nil
    ) async throws -> String? {
        progress?(0.05)

        // Find the helper binary next to the main executable
        let mainExe = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let helperPath = mainExe.deletingLastPathComponent().appendingPathComponent("GyroflowSyncHelper").path

        guard FileManager.default.fileExists(atPath: helperPath) else {
            throw GyroflowError.bridgeError("GyroflowSyncHelper not found at: \(helperPath)")
        }

        progress?(0.10)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        var args = [videoPath, gcsvPath, outputPath]
        args.append(lensProfilePath ?? "-")
        args.append(String(initialOffsetMs))
        args.append(String(searchSizeMs))
        args.append(imuOrientationMode ?? "")  // empty = heuristic
        args.append(frameReadoutTimeMs.map { String($0) } ?? "")  // empty = lens profile or none
        process.arguments = args

        // Capture stdout to read the `OK frames=N orientation=XXX` line.
        // Forward stderr to the parent's stderr so the helper's INFO logs
        // (sync offsets, install_angle, IMU orientation, etc.) appear when
        // the app is launched from a terminal — useful for debugging.
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        progress?(0.15)

        try process.run()

        // Wait in background to avoid blocking
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        progress?(0.90)

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            if process.terminationReason == .uncaughtSignal {
                throw GyroflowError.bridgeError("Sync crashed (signal \(exitCode)) - video may have insufficient motion")
            }
            throw GyroflowError.bridgeError("Sync failed (exit code \(exitCode))")
        }

        // Parse stdout for orientation. The helper only ever prints a single
        // short line ("OK frames=N orientation=XXX"), so we cap the read at
        // 64KB to avoid unbounded memory use if a future helper change spams
        // stdout. Anything past the cap is discarded.
        let outputData = stdoutPipe.fileHandleForReading.readData(ofLength: 64 * 1024)
        let outputStr = String(data: outputData, encoding: .utf8) ?? ""
        var detectedOrientation: String? = nil
        for line in outputStr.split(separator: "\n") {
            // Format: "OK frames=215 orientation=XyZ"
            if line.hasPrefix("OK") {
                for token in line.split(separator: " ") {
                    if token.hasPrefix("orientation=") {
                        let value = String(token.dropFirst("orientation=".count))
                        if !value.isEmpty { detectedOrientation = value }
                    }
                }
            }
        }

        progress?(1.0)
        return detectedOrientation
    }

    private func checkResult(_ result: Int32, _ errorPtr: inout UnsafeMutablePointer<CChar>?) throws {
        if result != 0 {
            let msg: String
            if let ptr = errorPtr {
                msg = String(cString: ptr)
                gf_free_string(ptr)
                errorPtr = nil
            } else {
                msg = "Unknown error (code: \(result))"
            }
            throw GyroflowError.bridgeError(msg)
        }
    }
}
