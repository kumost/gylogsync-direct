// main.swift (GyroflowSyncHelper)
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

// Single-video gyroflow sync helper - runs in subprocess for crash isolation
// Usage: GyroflowSyncHelper <videoPath> <gcsvPath> <outputPath> [lensProfilePath] [initialOffsetMs] [searchSizeMs] [imuOrientation]
// Exit codes: 0=success, 1=error, 139=SIGSEGV (caught by parent)

import Foundation
import AVFoundation
import CGyroflowBridge

// Read gcsv header only (lines until the first numeric data line).
func readGcsvHeader(fromGcsvAt path: String) -> String? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    var header = ""
    content.enumerateLines { line, stop in
        if !line.isEmpty, let first = line.first, (first.isNumber || first == "-") {
            stop = true
        } else {
            header += line + "\n"
        }
    }
    return header
}

// Scan a gcsv file's header for `install_angle:R{roll}_P{pitch}` and return
// the parsed angle, or nil if not present.
func extractInstallAngle(fromGcsvAt path: String) -> (roll: Double, pitch: Double)? {
    guard let header = readGcsvHeader(fromGcsvAt: path) else { return nil }
    let pattern = #"install_angle:R(-?\d+)_P(-?\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
          match.numberOfRanges >= 3,
          let rRange = Range(match.range(at: 1), in: header),
          let pRange = Range(match.range(at: 2), in: header),
          let roll = Double(header[rRange]),
          let pitch = Double(header[pRange])
    else { return nil }
    return (roll, pitch)
}

// Extract the `orientation,XYZ` (or similar 3-letter code) from the gcsv header.
// Gyroflow uses this as the axis-remap code for the IMU input.
func extractOrientation(fromGcsvAt path: String) -> String? {
    guard let header = readGcsvHeader(fromGcsvAt: path) else { return nil }
    let pattern = #"(?m)^orientation,([A-Za-z]{3,6})\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
          match.numberOfRanges >= 2,
          let r = Range(match.range(at: 1), in: header)
    else { return nil }
    return String(header[r])
}

// Extract the `id,...` field from the gcsv header (e.g. "iPhone_Motion_Logger"
// or "Android_Motion_Logger"). Used to platform-detect for imu_orientation
// defaults: iPhone needs "XYZ" (IMU axis = camera axis on same device), Android
// mirrorless rig uses whatever orientation the GyLog Android app wrote (typically
// "ZYx" for the standard USB-C-on-right mount).
func extractGcsvId(fromGcsvAt path: String) -> String? {
    guard let header = readGcsvHeader(fromGcsvAt: path) else { return nil }
    let pattern = #"(?m)^id,(.+)\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
          match.numberOfRanges >= 2,
          let r = Range(match.range(at: 1), in: header)
    else { return nil }
    return String(header[r]).trimmingCharacters(in: .whitespaces)
}

// Decide the imu_orientation to write into the .gyroflow project, based on
// platform detected from gcsv id.
//   iPhone_Motion_Logger  → "XYZ"  (iPhone camera use: IMU axes match camera axes;
//                                   for iPhone-mounted-on-mirrorless the user can
//                                   override in Gyroflow Desktop if needed)
//   Android_Motion_Logger → header's `orientation` value (typically "ZYx" for
//                                   standard Xperia mount); fallback "ZYx".
//   anything else         → header value or "ZYx" fallback
// Future v1.1: use gravity vector from GCSV header to auto-detect mount
// orientation for any phone position.
func resolveImuOrientation(forGcsvAt path: String) -> String {
    let gcsvId = extractGcsvId(fromGcsvAt: path) ?? ""
    if gcsvId.contains("iPhone") {
        return "XYZ"
    }
    return extractOrientation(fromGcsvAt: path) ?? "ZYx"
}

guard CommandLine.arguments.count >= 4 else {
    fputs("Usage: GyroflowSyncHelper <videoPath> <gcsvPath> <outputPath> [lensProfilePath] [initialOffsetMs] [searchSizeMs] [imuOrientation]\n", stderr)
    exit(1)
}

let videoPath = CommandLine.arguments[1]
let gcsvPath = CommandLine.arguments[2]
let outputPath = CommandLine.arguments[3]
let lensProfilePath = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil
let initialOffsetMs = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[5]) ?? 0 : 0.0
let searchSizeMs = CommandLine.arguments.count > 6 ? Double(CommandLine.arguments[6]) ?? 500 : 500.0
// 7th arg controls IMU orientation handling for batch optimization:
//   - "DETECT"      → run gyroflow-core's guess_imu_orientation (slow, ~90s)
//   - 3-letter axis → force this value (e.g. "XYZ", "XyZ", "ZYx") — fast (~4s)
//   - "" / missing  → use heuristic from gcsv id (iPhone→XYZ, Android→header)
// Typical batch usage: GUI calls helper with "DETECT" for the first clip, captures
// the result from stdout (`orientation=...`), then passes that string for clips 2-N
// to skip the slow detection pass since the physical mount is fixed across the batch.
let imuOrientationArg = CommandLine.arguments.count > 7 ? CommandLine.arguments[7] : ""

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

    // Frame-decoding helper: re-creates an AVAssetReader (single-use) and feeds
    // every frame to gf_feed_frame(). Returns the per-frame PTS list.
    let processingHeight = 720
    let scale = Double(processingHeight) / Double(height)
    let procWidth = Int(Double(width) * scale)

    func feedAllFrames() throws -> [Int64] {
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
        var ptsList: [Int64] = []
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestampUs = Int64(CMTimeGetSeconds(presentationTime) * 1_000_000.0)
            ptsList.append(timestampUs)
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
        return ptsList
    }

    // ── Pass 1: synchronization (compute time offsets) ──
    check(gf_start_sync(ctx, initialOffsetMs, searchSizeMs, &errorPtr), "start_sync")
    let framePtsUs = try feedAllFrames()
    check(gf_finish_sync(ctx, &errorPtr), "finish_sync")

    // ── Pass 2: IMU orientation handling ──
    // Three modes per imuOrientationArg:
    //   "DETECT"      → run gyroflow-core's guess_imu_orientation (~90s/clip)
    //   3-letter axis → skip detection, force this value (~4s/clip total)
    //   ""            → skip detection, use heuristic at post-process time
    var detectedOrientation: String? = nil
    let isExplicitOrientation = !imuOrientationArg.isEmpty &&
                                imuOrientationArg.uppercased() != "DETECT"

    if isExplicitOrientation {
        // Forced value — no detection pass needed (batch optimization: clips 2-N
        // can reuse the orientation detected on clip 1)
        detectedOrientation = imuOrientationArg
        fputs("INFO: Using forced IMU orientation = \(imuOrientationArg) (no detection)\n", stderr)
    } else if imuOrientationArg.uppercased() == "DETECT" {
        // Full optical-flow-based detection (slow). Used for clip 1 of a batch
        // or when user explicitly requests detection.
        fputs("INFO: Starting IMU orientation guess (pass 2/2)...\n", stderr)
        let orientStartResult = gf_start_orientation_guess(ctx, initialOffsetMs, searchSizeMs, &errorPtr)
        if orientStartResult == 0 {
            do {
                _ = try feedAllFrames()
            } catch {
                fputs("WARNING: Frame feed failed in orientation pass: \(error)\n", stderr)
            }
            let finishResult = gf_finish_orientation_guess(ctx, &errorPtr)
            if finishResult == 0 {
                if let cstr = gf_get_detected_orientation(ctx) {
                    detectedOrientation = String(cString: cstr)
                    gf_free_string(cstr)
                    fputs("INFO: IMU orientation auto-detected: \(detectedOrientation ?? "none")\n", stderr)
                } else {
                    fputs("WARNING: Orientation detection completed but no orientation returned\n", stderr)
                }
            } else {
                if let ptr = errorPtr { gf_free_string(ptr); errorPtr = nil }
                fputs("WARNING: gf_finish_orientation_guess failed (continuing with heuristic)\n", stderr)
            }
        } else {
            if let ptr = errorPtr { gf_free_string(ptr); errorPtr = nil }
            fputs("WARNING: gf_start_orientation_guess failed (continuing with heuristic)\n", stderr)
        }
    } else {
        // Empty arg — fall through to heuristic at post-process time
        fputs("INFO: No IMU orientation arg, will use heuristic from gcsv id\n", stderr)
    }

    check(gf_export(ctx, outputPath, &errorPtr), "export")

    // Post-process the .gyroflow JSON:
    // - Apply install_angle from gcsv to gyro_source.rotation (rig auto-leveling)
    // - Set imu_orientation by auto-detecting platform from gcsv id:
    //     iPhone_Motion_Logger  → "XYZ"  (IMU axes = camera axes for iPhone)
    //     Android_Motion_Logger → header's value (typically "ZYx" for Xperia mount)
    // - KEEP sync offsets (computed by gf_finish_sync above) so DaVinci OFX
    //   plugin works without user action. OFX plugin has no Auto sync feature
    //   (per Gyroflow docs), so Mac-side optical flow sync is REQUIRED for
    //   the "Direct to DaVinci" workflow. If sync accuracy is insufficient
    //   for a given clip, user can fall back to opening the .gyroflow in
    //   Gyroflow Desktop and re-running Auto sync there.
    //
    // NOTE: we do NOT embed `frame_timestamps_us` here. Earlier versions did
    // (hoping OFX would use exact PTS), but v1.0-beta.6 testing showed OFX
    // v2.1.1 misinterprets the field and applies rotation ~180° inverted.
    // Removing it lets OFX compute timing the standard way.
    do {
        let gyroflowData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        if var json = try JSONSerialization.jsonObject(with: gyroflowData) as? [String: Any] {
            var dirty = false

            var gyroSource = (json["gyro_source"] as? [String: Any]) ?? [:]

            if let angle = extractInstallAngle(fromGcsvAt: gcsvPath) {
                gyroSource["rotation"] = [angle.pitch, angle.roll, 0.0]
                dirty = true
                fputs("INFO: Applied install_angle R\(Int(angle.roll))_P\(Int(angle.pitch)) -> gyro_source.rotation\n", stderr)
            }

            // Prefer the auto-detected orientation (from "guess_imu_orientation"
            // pass) over the platform heuristic. Detection is empirical/optical-
            // flow based, so for clips with sufficient motion it's more reliable
            // than guessing from gcsv id alone. Fall back to heuristic only if
            // detection failed or returned nothing.
            let heuristicOrientation = resolveImuOrientation(forGcsvAt: gcsvPath)
            let imuOrientation = detectedOrientation ?? heuristicOrientation
            gyroSource["imu_orientation"] = imuOrientation
            dirty = true
            let gcsvId = extractGcsvId(fromGcsvAt: gcsvPath) ?? "unknown"
            let source = (detectedOrientation != nil) ? "auto-detected" : "heuristic from gcsv id"
            fputs("INFO: Set imu_orientation = \(imuOrientation) (\(source); gcsv id: \(gcsvId))\n", stderr)

            if !gyroSource.isEmpty {
                json["gyro_source"] = gyroSource
            }

            // Propagate frame_readout_time from the loaded lens profile into
            // stabilization.frame_readout_time so rolling-shutter correction
            // actually activates when the .gyroflow is read by OFX or Desktop.
            // Gyroflow's lens profile JSON stores this either at the top level
            // ("frame_readout_time") or per-fps in "compatible_settings". Prefer
            // the per-fps match when the video's fps is listed.
            if let lensPath = lensProfilePath, lensPath != "-",
               let lensData = try? Data(contentsOf: URL(fileURLWithPath: lensPath)),
               let lens = try? JSONSerialization.jsonObject(with: lensData) as? [String: Any] {
                var rsTime: Double? = nil
                // Try per-fps match first
                if let compat = lens["compatible_settings"] as? [[String: Any]] {
                    for entry in compat {
                        if let entryFps = entry["fps"] as? Double,
                           abs(entryFps - fps) < 0.5,
                           let t = entry["frame_readout_time"] as? Double {
                            rsTime = t
                            break
                        }
                    }
                }
                // Fallback to top-level
                if rsTime == nil, let t = lens["frame_readout_time"] as? Double, t > 0 {
                    rsTime = t
                }
                if let t = rsTime {
                    var stab = (json["stabilization"] as? [String: Any]) ?? [:]
                    stab["frame_readout_time"] = t
                    json["stabilization"] = stab
                    dirty = true
                    fputs("INFO: Applied frame_readout_time = \(t) from lens profile\n", stderr)
                } else {
                    fputs("INFO: Lens profile has no frame_readout_time for fps=\(fps); rolling-shutter correction disabled\n", stderr)
                }
            }

            // NOTE: sync offsets are intentionally KEPT (not cleared) so that
            // DaVinci OFX plugin works without user action. The OFX plugin
            // has no Auto sync feature.
            fputs("INFO: Sync offsets kept (computed by gf_finish_sync, embedded for OFX direct workflow)\n", stderr)

            if dirty {
                let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: outputPath))
            }
        }
    } catch {
        fputs("WARNING: Failed to post-process .gyroflow: \(error)\n", stderr)
    }

    // Print result to stdout for parent to parse.
    // Format: `OK frames=N orientation=XXX`
    //   - orientation field is the value actually written to .gyroflow (either
    //     forced, detected, or heuristic). GUI uses this to remember the value
    //     across a batch and skip detection on subsequent clips.
    let writtenOrientation = detectedOrientation ?? resolveImuOrientation(forGcsvAt: gcsvPath)
    print("OK frames=\(framePtsUs.count) orientation=\(writtenOrientation)")
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
