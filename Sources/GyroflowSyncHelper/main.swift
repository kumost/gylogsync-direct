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
    fputs("Usage: GyroflowSyncHelper <videoPath> <gcsvPath> <outputPath> [lensProfilePath] [initialOffsetMs] [searchSizeMs] [imuOrientation] [frameReadoutTimeMs]\n", stderr)
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
// 8th arg: manual frame_readout_time override in ms. Empty/"-"/non-positive = no
// override (lens profile value used if available). Non-zero positive = force this
// value into stabilization.frame_readout_time, overriding any lens profile value.
// Sourced by user from horshack DB or empirical Gyroflow Desktop measurement.
let frameReadoutTimeMsArg = CommandLine.arguments.count > 8 ? CommandLine.arguments[8] : ""
let frameReadoutTimeOverride: Double? = {
    let parsed = Double(frameReadoutTimeMsArg) ?? 0
    return parsed > 0 ? parsed : nil
}()

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
        // Reusable de-padded Y-plane buffer (allocated lazily on first frame
        // and re-grown only when dimensions change). Previously this was
        // allocated per-frame, causing multi-GB of churn on long clips.
        var compactBuf: [UInt8] = []
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestampUs = Int64(CMTimeGetSeconds(presentationTime) * 1_000_000.0)
            ptsList.append(timestampUs)
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
                gf_feed_frame(ctx, timestampUs, frameNo, UInt32(yWidth), UInt32(yHeight), UInt32(yWidth),
                             bufBase, UInt32(yWidth * yHeight))
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
    // Two modes per imuOrientationArg:
    //   3-letter axis → force this value into the .gyroflow (e.g. "ZYx")
    //   ""            → fall through to heuristic at post-process time
    //                   (iPhone → "XYZ", Android → header value or "ZYx")
    //
    // The previous "DETECT" mode (gyroflow-core's guess_imu_orientation) was
    // removed in v2.0-beta because real-world testing produced wrong values
    // (e.g. "xYZ" for a USB-C-right Android mount where "ZYx" is correct).
    // The connector-side selector in the GUI replaces it.
    var detectedOrientation: String? = nil
    if !imuOrientationArg.isEmpty {
        detectedOrientation = imuOrientationArg
        fputs("INFO: Using forced IMU orientation = \(imuOrientationArg)\n", stderr)
    } else {
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
        let parsedJson = try JSONSerialization.jsonObject(with: gyroflowData)
        guard var json = parsedJson as? [String: Any] else {
            // gyroflow_core's gf_export should always produce an object root.
            // If it doesn't, the post-process (calibration_data cleanup,
            // install_angle injection, IMU orientation, frame_readout_time)
            // is silently skipped — and the output .gyroflow won't have any
            // of those critical fields. Make the failure loud so we know.
            fputs("ERROR: .gyroflow root is not a JSON object (got \(type(of: parsedJson))); post-process skipped — output will be incomplete\n", stderr)
            throw NSError(domain: "GyroflowSyncHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected .gyroflow root type"])
        }
        // Inner block kept to preserve original brace nesting (post-process
        // body was previously inside `if var json = ...` block).
        do {
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

            // Strip calibration_data ONLY when it's truly empty (no lens profile
            // was loaded). gyroflow-core's exporter writes a calibration_data
            // block even when nothing was loaded — empty brand/model/distortion
            // and a zero-sized calib_dimension. Desktop's loader rejects this
            // empty-but-present block ("Failed to load the selected file").
            //
            // CRITICAL: when a lens profile IS loaded, gyroflow-core leaves
            // brand/model/distortion_model empty in the export but DOES populate
            // calib_dimension and the fisheye_params camera_matrix. Stripping
            // based on brand/model alone (earlier bug) would drop a real lens
            // profile and leave the .gyroflow without any lens correction.
            //
            // Detection rule: if calib_dimension has a non-zero width and
            // height, a real lens profile was loaded — keep calibration_data.
            // Otherwise it's the empty placeholder — drop it.
            if let calibration = json["calibration_data"] as? [String: Any] {
                let calibDim = (calibration["calib_dimension"] as? [String: Any]) ?? [:]
                let calibW = (calibDim["w"] as? Double) ?? Double((calibDim["w"] as? Int) ?? 0)
                let calibH = (calibDim["h"] as? Double) ?? Double((calibDim["h"] as? Int) ?? 0)
                let hasRealLensData = calibW > 0 && calibH > 0
                if !hasRealLensData {
                    json.removeValue(forKey: "calibration_data")
                    dirty = true
                    fputs("INFO: Dropped empty calibration_data placeholder (no lens profile loaded)\n", stderr)
                } else {
                    fputs("INFO: Kept calibration_data (lens profile loaded: \(Int(calibW))x\(Int(calibH)))\n", stderr)
                }
            }

            // Propagate frame_readout_time into stabilization.frame_readout_time
            // so rolling-shutter correction actually activates when the .gyroflow
            // is read by OFX or Desktop. Priority:
            //   1. User override (8th CLI arg) — highest priority, overrides everything.
            //      Used for manual values from horshack DB or Gyroflow Desktop tuning.
            //   2. Lens profile per-fps match in "compatible_settings".
            //   3. Lens profile top-level "frame_readout_time".
            //   4. None → rolling-shutter correction disabled.
            var rsTime: Double? = nil
            var rsSource: String = ""
            if let override = frameReadoutTimeOverride {
                rsTime = override
                rsSource = "user override"
            } else if let lensPath = lensProfilePath, lensPath != "-",
                      let lensData = try? Data(contentsOf: URL(fileURLWithPath: lensPath)),
                      let lens = try? JSONSerialization.jsonObject(with: lensData) as? [String: Any] {
                if let compat = lens["compatible_settings"] as? [[String: Any]] {
                    for entry in compat {
                        if let entryFps = entry["fps"] as? Double,
                           abs(entryFps - fps) < 0.5,
                           let t = entry["frame_readout_time"] as? Double {
                            rsTime = t
                            rsSource = "lens profile per-fps"
                            break
                        }
                    }
                }
                if rsTime == nil, let t = lens["frame_readout_time"] as? Double, t > 0 {
                    rsTime = t
                    rsSource = "lens profile top-level"
                }
            }
            if let t = rsTime {
                var stab = (json["stabilization"] as? [String: Any]) ?? [:]
                stab["frame_readout_time"] = t
                json["stabilization"] = stab
                dirty = true
                fputs("INFO: Applied frame_readout_time = \(t) ms (\(rsSource))\n", stderr)
            } else {
                fputs("INFO: No frame_readout_time set; rolling-shutter correction disabled\n", stderr)
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
