// ReportWriter.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct
//
// Writes a per-folder CSV report of a batch run so the user has a record of
// what was processed, with what settings, and whether each output was
// produced successfully. Mirrors gylogsync-v4.0's ReportWriter but:
//   - drops audio_status (Direct doesn't process audio)
//   - adds gyroflow_status, frame_readout_time_ms, imu_orientation,
//     lens_profile, sync_offset_ms (Direct-specific outputs)

import Foundation

struct DirectReportRow {
    let videoURL: URL
    let videoStart: Date
    let videoEnd: Date
    let duration: Double
    let logSliceStart: Date
    let logSliceEnd: Date
    let logSamples: Int
    let logCovered: String
    let timingFix: String
    let timeOffsetApplied: Double
    let imuOrientationUsed: String
    let frameReadoutTimeMs: Double?       // nil = no override / no lens profile value
    let lensProfileName: String           // empty if none
    let syncOffsetMs: Double?             // nil = sync failed or fallback path
    let gyroflowStatus: String            // "OK" / "fallback" / "failed: ..."
    let status: String                    // overall status

    var folder: URL { videoURL.deletingLastPathComponent() }
    var filename: String { videoURL.lastPathComponent }
}

struct DirectSessionInfo {
    let generated: Date
    let sourceGCSV: String
    let device: String
    let appVersion: String
    let imuOrientationBatch: String      // batch-fixed orientation (after clip-1 detection)
    let installAngleRoll: Int            // 0 if absent in GCSV
    let installAnglePitch: Int           // 0 if absent in GCSV
    let logRangeStart: Date
    let logRangeEnd: Date
    let timeScale: String
    let valueScale: String
    let note: String
    let timeOffsetApplied: Double
    let sliceBuffer: Double
    let frameReadoutTimeMs: Double?
    let lensProfileName: String
}

enum DirectReportWriter {
    private static let columns = [
        "video_file",
        "video_start",
        "video_end",
        "duration_sec",
        "log_slice_start",
        "log_slice_end",
        "log_samples",
        "log_covered",
        "timing_fix",
        "time_offset_applied",
        "imu_orientation",
        "frame_readout_time_ms",
        "lens_profile",
        "sync_offset_ms",
        "gyroflow_status",
        "status"
    ]

    struct WriteResult {
        var written: [URL]
        var errors: [String]
    }

    /// Group rows by source folder and write one CSV per folder.
    @discardableResult
    static func writeGrouped(rows: [DirectReportRow], session: DirectSessionInfo) -> WriteResult {
        let grouped = Dictionary(grouping: rows) { $0.folder }
        var result = WriteResult(written: [], errors: [])
        for (folder, folderRows) in grouped {
            do {
                let url = try write(rows: folderRows, session: session, to: folder)
                result.written.append(url)
            } catch {
                result.errors.append("Report write failed for \(folder.lastPathComponent)/: \(error.localizedDescription)")
            }
        }
        return result
    }

    static func write(rows: [DirectReportRow], session: DirectSessionInfo, to folder: URL) throws -> URL {
        let fileFmt = DateFormatter()
        fileFmt.dateFormat = "yyyyMMdd_HHmmss"
        fileFmt.locale = Locale(identifier: "en_US_POSIX")

        let cellFmt = DateFormatter()
        cellFmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        cellFmt.locale = Locale(identifier: "en_US_POSIX")

        // Filename: GyLogDirect_P{pitch}_R{roll}_YYYYMMDD_HHMMSS.csv
        // Pitch-then-Roll order matches Gyroflow Desktop's rotation input field.
        let anglePart = "P\(session.installAnglePitch)_R\(session.installAngleRoll)"
        let filename = "GyLogDirect_\(anglePart)_\(fileFmt.string(from: session.generated)).csv"
        let url = folder.appendingPathComponent(filename)

        var lines: [String] = []

        // ── [Session] block ──
        lines.append("[Session]")
        lines.append("Generated,\(escape(cellFmt.string(from: session.generated)))")
        lines.append("Source GCSV,\(escape(session.sourceGCSV))")
        lines.append("Device,\(escape(session.device))")
        lines.append("App Version,\(escape(session.appVersion))")
        lines.append("IMU Orientation (batch),\(escape(session.imuOrientationBatch))")
        lines.append("Install Angle Roll,\(session.installAngleRoll)")
        lines.append("Install Angle Pitch,\(session.installAnglePitch)")
        lines.append("Log Range Start,\(escape(cellFmt.string(from: session.logRangeStart)))")
        lines.append("Log Range End,\(escape(cellFmt.string(from: session.logRangeEnd)))")
        lines.append("Time Scale,\(escape(session.timeScale))")
        lines.append("Value Scale,\(escape(session.valueScale))")
        lines.append("Note,\(escape(session.note))")
        lines.append("Time Offset Applied,\(String(format: "%.3f", session.timeOffsetApplied))")
        lines.append("Slice Buffer,\(String(format: "%.1f", session.sliceBuffer))")
        lines.append("Frame Readout Time (ms),\(session.frameReadoutTimeMs.map { String(format: "%g", $0) } ?? "")")
        lines.append("Lens Profile,\(escape(session.lensProfileName))")

        // Blank separator row
        lines.append("")

        // ── [Clips] block ──
        lines.append("[Clips]")
        lines.append(columns.joined(separator: ","))
        for row in rows {
            let fields: [String] = [
                escape(row.filename),
                cellFmt.string(from: row.videoStart),
                cellFmt.string(from: row.videoEnd),
                String(format: "%.3f", row.duration),
                cellFmt.string(from: row.logSliceStart),
                cellFmt.string(from: row.logSliceEnd),
                String(row.logSamples),
                escape(row.logCovered),
                escape(row.timingFix),
                String(format: "%.3f", row.timeOffsetApplied),
                escape(row.imuOrientationUsed),
                row.frameReadoutTimeMs.map { String(format: "%g", $0) } ?? "",
                escape(row.lensProfileName),
                row.syncOffsetMs.map { String(format: "%.2f", $0) } ?? "",
                escape(row.gyroflowStatus),
                escape(row.status)
            ]
            lines.append(fields.joined(separator: ","))
        }

        let csv = lines.joined(separator: "\n") + "\n"
        try FileUtils.preserveIfExists(url)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
