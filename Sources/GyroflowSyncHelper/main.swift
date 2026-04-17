// main.swift (GyroflowSyncHelper)
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/GyLogSync

// Single-video gyroflow sync helper - runs in subprocess for crash isolation
// Usage: GyroflowSyncHelper <videoPath> <gcsvPath> <outputPath> [lensProfilePath] [initialOffsetMs] [searchSizeMs]
// Exit codes: 0=success, 1=error, 139=SIGSEGV (caught by parent)

import Foundation
import AVFoundation
import CGyroflowBridge

guard CommandLine.arguments.count >= 4 else {
    fputs("Usage: GyroflowSyncHelper <videoPath> <gcsvPath> <outputPath> [lensProfilePath] [initialOffsetMs] [searchSizeMs]\n", stderr)
    exit(1)
}

let videoPath = CommandLine.arguments[1]
let gcsvPath = CommandLine.arguments[2]
let outputPath = CommandLine.arguments[3]
let lensProfilePath = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil
let initialOffsetMs = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[5]) ?? 0 : 0.0
let searchSizeMs = CommandLine.arguments.count > 6 ? Double(CommandLine.arguments[6]) ?? 500 : 500.0

func run() async throws {
    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let videoTrack = tracks.first else {
        fputs("ERROR: No video track\n", stderr)
        exit(1)
    }

    let naturalSize = try await videoTrack.load(.naturalSize)
    let frameRate = try await videoTrack.load(.nominalFrameRate)
    let width = Int(naturalSize.width)
    let height = Int(naturalSize.height)
    let fps = Double(frameRate)
    let durationMs = CMTimeGetSeconds(duration) * 1000.0
    let frameCount = Int(CMTimeGetSeconds(duration) * fps)

    guard let ctx = gf_context_new() else {
        fputs("ERROR: Context creation failed\n", stderr)
        exit(1)
    }
    defer { gf_context_free(ctx) }

    var errorPtr: UnsafeMutablePointer<CChar>? = nil

    func check(_ result: Int32, _ step: String) {
        if result != 0 {
            let msg = errorPtr.map { String(cString: $0) } ?? "unknown"
            if let ptr = errorPtr { gf_free_string(ptr) }
            fputs("ERROR [\(step)]: \(msg)\n", stderr)
            exit(1)
        }
    }

    check(gf_init_video(ctx, videoPath, UInt32(width), UInt32(height), fps, durationMs, UInt32(frameCount), &errorPtr), "init_video")
    check(gf_load_gyro(ctx, gcsvPath, &errorPtr), "load_gyro")

    if let lensPath = lensProfilePath, lensPath != "-" {
        let r = gf_load_lens_profile(ctx, lensPath, &errorPtr)
        if r != 0 {
            if let ptr = errorPtr { gf_free_string(ptr); errorPtr = nil }
            fputs("WARNING: Lens profile load failed (continuing)\n", stderr)
        }
    }

    check(gf_start_sync(ctx, initialOffsetMs, searchSizeMs, &errorPtr), "start_sync")

    // Decode and feed frames
    let processingHeight = 720
    let scale = Double(processingHeight) / Double(height)
    let procWidth = Int(Double(width) * scale)

    let reader = try AVAssetReader(asset: asset)
    let outputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: procWidth,
        kCVPixelBufferHeightKey as String: processingHeight,
    ]
    let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
    trackOutput.alwaysCopiesSampleData = false
    reader.add(trackOutput)

    guard reader.startReading() else {
        fputs("ERROR: Cannot start reading\n", stderr)
        exit(1)
    }

    var frameNo: UInt32 = 0
    var framePtsUs: [Int64] = []  // Collect per-frame PTS for .gyroflow embedding
    while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampUs = Int64(CMTimeGetSeconds(presentationTime) * 1_000_000.0)
        framePtsUs.append(timestampUs)

        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
            let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

            let src = yPlane.assumingMemoryBound(to: UInt8.self)
            var compactBuf = [UInt8](repeating: 0, count: yWidth * yHeight)
            for row in 0..<yHeight {
                compactBuf.withUnsafeMutableBufferPointer { dst in
                    memcpy(dst.baseAddress! + row * yWidth, src + row * yStride, yWidth)
                }
            }
            compactBuf.withUnsafeBufferPointer { buf in
                gf_feed_frame(ctx, timestampUs, frameNo, UInt32(yWidth), UInt32(yHeight), UInt32(yWidth),
                             buf.baseAddress!, UInt32(yWidth * yHeight))
            }
        }
        frameNo += 1
    }

    check(gf_finish_sync(ctx, &errorPtr), "finish_sync")
    check(gf_export(ctx, outputPath, &errorPtr), "export")

    // Embed per-frame PTS timestamps into .gyroflow file
    // This allows OFX plugins to use exact frame timing instead of computing from fps
    if !framePtsUs.isEmpty {
        do {
            let gyroflowData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
            if var json = try JSONSerialization.jsonObject(with: gyroflowData) as? [String: Any] {
                json["frame_timestamps_us"] = framePtsUs
                let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: outputPath))
                fputs("INFO: Embedded \(framePtsUs.count) frame timestamps\n", stderr)
            }
        } catch {
            fputs("WARNING: Failed to embed frame timestamps: \(error)\n", stderr)
        }
    }

    // Print result to stdout for parent to parse
    print("OK frames=\(frameNo)")
}

Task {
    do {
        try await run()
    } catch {
        fputs("FATAL: \(error)\n", stderr)
        exit(1)
    }
    exit(0)
}

RunLoop.main.run()
