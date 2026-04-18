// main.swift (GyLogSyncTest)
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

// CLI batch test for Gyroflow sync bridge — full subprocess isolation
import Foundation
import AVFoundation

signal(SIGPIPE, SIG_IGN)

struct VideoResult {
    let name: String
    let offsets: [(String, Any)]
    let elapsed: Double
    let error: String?
    let fallback: Bool
}

/// Run a helper binary in a fully isolated subprocess via /bin/sh
func runHelper(helperPath: String, args: [String]) -> Int32 {
    let escapedArgs = args.map { "\"\($0)\"" }.joined(separator: " ")
    let shellCmd = "\"\(helperPath)\" \(escapedArgs) 2>/dev/null"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", shellCmd]
    process.standardOutput = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return -1
    }
}

func runBatchTest() async throws {
    let videoDir = "/path/to/videos"
    let gcsvDir = "/path/to/videos/gcsv"
    let lensProfilePath = "/path/to/lens_profile.json"
    let outputDir = "/tmp"

    let mainExe = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    let helperPath = mainExe.deletingLastPathComponent().appendingPathComponent("GyroflowSyncHelper").path

    guard FileManager.default.fileExists(atPath: helperPath) else {
        print("ERROR: GyroflowSyncHelper not found at \(helperPath)")
        return
    }

    let fm = FileManager.default
    let videos = try fm.contentsOfDirectory(atPath: videoDir)
        .filter { $0.hasSuffix(".mov") }
        .sorted()

    print("=== Gyroflow Batch Sync Test (subprocess isolation) ===")
    print("Videos: \(videos.count)")
    print("Initial offset: 0ms, Search: 1000ms")
    print("Lens profile: iPhone17pro_24mm.json")
    print(String(repeating: "=", count: 80))
    print("")

    var results: [VideoResult] = []
    let batchStart = Date()

    for (i, videoFile) in videos.enumerated() {
        let baseName = URL(fileURLWithPath: videoFile).deletingPathExtension().lastPathComponent
        let videoPath = "\(videoDir)/\(videoFile)"
        let gcsvPath = "\(gcsvDir)/\(baseName).gcsv"
        let outputPath = "\(outputDir)/batch_\(baseName).gyroflow"

        guard fm.fileExists(atPath: gcsvPath) else {
            print("[\(i+1)/\(videos.count)] \(baseName) — SKIP (no GCSV)")
            results.append(VideoResult(name: baseName, offsets: [], elapsed: 0, error: "No GCSV file", fallback: false))
            continue
        }

        print("[\(i+1)/\(videos.count)] \(baseName)...", terminator: " ")
        fflush(stdout)

        let startTime = Date()

        // Run optical flow sync in subprocess
        let exitCode = runHelper(helperPath: helperPath, args: [
            videoPath, gcsvPath, outputPath, lensProfilePath, "0", "1000"
        ])

        let elapsed = Date().timeIntervalSince(startTime)

        if exitCode != 0 {
            // Sync failed - note it and continue (no fallback for now in CLI test)
            print("FAILED (exit \(exitCode)), \(String(format: "%.1f", elapsed))s")
            results.append(VideoResult(name: baseName, offsets: [], elapsed: elapsed, error: "sync exit \(exitCode)", fallback: false))
            continue
        }

        // Read offsets from exported file
        var offsets: [(String, Any)] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: outputPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let offsetMap = json["offsets"] as? [String: Any] {
            offsets = offsetMap.sorted(by: { $0.key < $1.key })
        }

        let offsetValues = offsets.map { String(format: "%.1f", ($0.1 as? Double) ?? 0) }
        print("\(offsets.count) offsets: [\(offsetValues.joined(separator: ", "))]ms  (\(String(format: "%.1f", elapsed))s)")

        results.append(VideoResult(name: baseName, offsets: offsets, elapsed: elapsed, error: nil, fallback: false))
    }

    let totalTime = Date().timeIntervalSince(batchStart)

    // Summary
    print("")
    print(String(repeating: "=", count: 80))
    print("=== SUMMARY ===")
    print(String(repeating: "=", count: 80))

    let succeeded = results.filter { $0.error == nil }
    let failed = results.filter { $0.error != nil }

    print("Total: \(results.count) videos, \(succeeded.count) OK, \(failed.count) failed")
    print("Total time: \(String(format: "%.1f", totalTime))s")
    print("")

    // Offset table
    for r in results {
        if let err = r.error {
            print("  \(r.name): ERROR - \(err)")
        } else {
            let offsetStr = r.offsets.map { String(format: "%.1f", ($0.1 as? Double) ?? 0) }.joined(separator: ", ")
            print("  \(r.name): [\(offsetStr)]ms")
        }
    }

    // Consistency check
    print("")
    print("=== OFFSET CONSISTENCY ===")
    for r in succeeded {
        let offVals = r.offsets.compactMap { $0.1 as? Double }
        if offVals.isEmpty { continue }
        let avg = offVals.reduce(0, +) / Double(offVals.count)
        let maxDev = offVals.map { abs($0 - avg) }.max() ?? 0
        let status = maxDev < 50 ? "OK" : "WARN"
        print("  \(r.name): avg=\(String(format: "%.1f", avg))ms  maxDev=\(String(format: "%.1f", maxDev))ms  [\(status)]")
    }
}

Task {
    do {
        try await runBatchTest()
    } catch {
        print("FATAL: \(error)")
    }
    exit(0)
}

RunLoop.main.run()
