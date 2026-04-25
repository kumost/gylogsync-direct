// ContentView.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AppKit

struct ContentView: View {
    @State private var statusMessage = "Drag & Drop a Folder containing .gcsv and Videos."
    @State private var isProcessing = false
    @State private var processedFiles: [String] = []
    @State private var timeOffset: Double = 0.0
    @State private var showAdvanced = true

    // New: Accumulated files for staged processing
    @State private var accumulatedGCSV: [URL] = []
    @State private var accumulatedVideo: [URL] = []

    // Progress tracking
    @State private var currentProgress: Int = 0
    @State private var totalProgress: Int = 0

    // Gyroflow processing options.
    // searchSizeMs is the window gyroflow-core searches for the optimal
    // video↔gyro offset. Default 5000ms covers typical manual-sync camera
    // clock drift (±1-2s realistic, up to ±5s worst case on mirrorless rigs
    // whose clock was set a few days ago).
    @State private var gyroflowSearchSize: Double = 5000

    // Optional lens profile JSON. If set, embedded as `calibration_data` in
    // every .gyroflow so DaVinci OFX applies lens correction without a manual
    // "Load lens profile" step (which is broken in gyroflow-plugins v2.1.1).
    // One batch = one rig config = one lens, per the "change lens → new log"
    // workflow rule. Leave empty for the "manual in Gyroflow Desktop" path.
    @State private var lensProfileURL: URL? = nil

    // Phone connector side preset for the mirrorless mount. Maps to a fixed
    // IMU orientation string:
    //   right (USB-C/Lightning on right of camera, screen up): "ZYx"
    //   left  (USB-C/Lightning on left  of camera, screen up): "zYX"
    // Mount tilt (pitch/roll) is captured separately by install_angle from
    // GyLog's Calibrate Mount and applied via gyro_source.rotation, so this
    // selector only needs to handle the discrete connector-side flip.
    @State private var connectorSide: String = "right"

    // Optional advanced override. If non-empty, takes priority over the
    // connector-side preset and forces this exact 3-letter axis code into
    // every clip's .gyroflow (e.g. "XYZ" for an iPhone-on-mirrorless rig
    // that doesn't match the standard Android conventions, or any unusual
    // mount). Leave empty to use the connector-side preset.
    @State private var imuOrientationOverride: String = ""

    // Optional Rolling Shutter (frame readout time, ms) override. If set,
    // wins over any frame_readout_time in the lens profile and is written to
    // every clip's stabilization.frame_readout_time. Source the value from
    // horshack DB (https://horshack-dpreview.github.io/RollingShutter/) or
    // empirically by tuning Gyroflow Desktop's Frame Readout Time slider on
    // one clip until shake is minimized. Resets to blank on each launch so a
    // forgotten value from a prior session can't silently apply to a fresh
    // batch (matches the other Advanced Options fields).
    @State private var rollingShutterMsText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Minimal Header
            HStack {
                Text("GyLog Sync Direct (β)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Main Content
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                        .foregroundColor(.primary.opacity(0.2))
                    
                    if isProcessing {
                        VStack(spacing: 15) {
                            ProgressView(value: Double(currentProgress), total: Double(totalProgress))
                                .frame(width: 200)
                            Text("Processing \(currentProgress)/\(totalProgress)")
                                .font(.body)
                        }
                    } else {
                        VStack(spacing: 10) {
                            Text("Drag & Drop Files")
                                .font(.headline)

                            Text("Add files, then click Sync")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            // File count display
                            HStack(spacing: 15) {
                                Label("\(accumulatedGCSV.count)", systemImage: "doc.text")
                                Label("\(accumulatedVideo.count)", systemImage: "video")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(height: 140)
                .padding(.top)
                
                // Control Buttons
                HStack(spacing: 12) {
                    Button(action: clearAccumulatedFiles) {
                        Label("Clear", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(accumulatedGCSV.isEmpty && accumulatedVideo.isEmpty)

                    Button(action: { Task { await executeSync() } }) {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accumulatedVideo.isEmpty || accumulatedGCSV.isEmpty || isProcessing)
                }
                .padding(.horizontal)

                // Advanced Options
                DisclosureGroup("Advanced Options", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Camera Clock Drift
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Camera Clock Drift (sec):")
                                TextField("0.0", value: $timeOffset, formatter: NumberFormatter())
                                    .frame(width: 60)
                                    .textFieldStyle(.roundedBorder)
                                Stepper("", value: $timeOffset, in: -86400...86400, step: 0.5)
                                Text(timeOffset > 0 ? "(Camera is ahead)" : timeOffset < 0 ? "(Camera is behind)" : "(No offset)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("If auto-sync keeps failing, open one clip in Gyroflow Desktop, measure the drift, then enter it here. Applied to every clip in the batch.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        // Gyroflow Options
                        HStack {
                            Text("Sync search range (ms):")
                            TextField("5000", value: $gyroflowSearchSize, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }

                        Divider()

                        // Phone connector side (USB-C / Lightning) for mirrorless
                        // mount. Maps to IMU orientation. Tilt is auto-handled
                        // by install_angle from GyLog Calibrate Mount.
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Phone connector side:")
                                Picker("", selection: $connectorSide) {
                                    Text("Right (default)").tag("right")
                                    Text("Left").tag("left")
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 200)
                                .labelsHidden()
                                Spacer()
                            }
                            Text("Which side of the camera the phone's USB-C / Lightning connector points. Tilt and pitch are auto-detected from GyLog's Calibrate Mount (install_angle in the gcsv header). For iPhone standalone clips (no install_angle), XYZ is used automatically.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        // Optional advanced override for unusual mounts
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("IMU orientation override (advanced):")
                                TextField("(empty = use connector side above)", text: $imuOrientationOverride)
                                    .frame(width: 200)
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                Spacer()
                            }
                            Text("Optional. Enter a 3-letter axis code (e.g. ZYx, zYX, XYZ) to force a specific IMU orientation, overriding the connector side preset above. Use this for unusual mounts (vertical phone, upside-down, screen-down, etc.) — find the right value by running Gyroflow Desktop's Auto-detect IMU orientation on one clip from the rig.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        // Rolling Shutter (optional, per-batch). User-supplied
                        // frame_readout_time in ms. See horshack DB or measure
                        // in Gyroflow Desktop, then type the value here.
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Rolling Shutter (ms):")
                                TextField("0.0", text: $rollingShutterMsText)
                                    .frame(width: 100)
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                Text("e.g. 31.0 for A7R II 4K 24p")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            Text("Type the frame readout time in milliseconds. Look it up at horshack-dpreview.github.io/RollingShutter, or measure your own value with Gyroflow Desktop's Frame Readout Time slider. Leave blank to fall back to the value embedded in your lens profile (if any). When set, output filename gets a _RS{value}ms suffix so different values coexist in the same folder for DaVinci's auto-load to find — delete unwanted variants if multiple are present.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        // Lens profile (optional, per-batch)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Lens profile:")
                                if let url = lensProfileURL {
                                    Text(url.lastPathComponent)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } else {
                                    Text("(none — embed later in Gyroflow Desktop)")
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Choose...") { chooseLensProfile() }
                                if lensProfileURL != nil {
                                    Button("Clear") { lensProfileURL = nil }
                                }
                            }
                            Text("Optional. If set, embedded in every .gyroflow so DaVinci OFX applies lens correction directly. One log = one fixed rig = one lens.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                    }
                    .padding(.top, 5)
                }
                .padding(.horizontal)
                .focusable(false) // Remove focus ring
                
                // File List Display
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files to Process")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 5)

                    List {
                        if !accumulatedGCSV.isEmpty {
                            Section(header: Text("Logs (\(accumulatedGCSV.count))").font(.caption2)) {
                                ForEach(accumulatedGCSV, id: \.self) { file in
                                    HStack {
                                        Image(systemName: "doc.text")
                                        Text(file.lastPathComponent)
                                            .font(.system(.caption2, design: .monospaced))
                                        Spacer()
                                    }
                                }
                            }
                        }

                        if !accumulatedVideo.isEmpty {
                            Section(header: Text("Videos (\(accumulatedVideo.count))").font(.caption2)) {
                                ForEach(accumulatedVideo, id: \.self) { file in
                                    HStack {
                                        Image(systemName: "video")
                                        Text(file.lastPathComponent)
                                            .font(.system(.caption2, design: .monospaced))
                                        Spacer()
                                    }
                                }
                            }
                        }

                        if accumulatedGCSV.isEmpty && accumulatedVideo.isEmpty {
                            Text("No files added yet")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    .listStyle(.inset)
                    .frame(maxHeight: 150)
                }

                Divider()

                // Processing History
                VStack(alignment: .leading) {
                    Text("Processing History")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 5)

                    List {
                        if processedFiles.isEmpty {
                            Text("No processing done yet")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        } else {
                            ForEach(processedFiles, id: \.self) { file in
                                Text(file)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            processDrop(providers: providers)
            return true
        }
    }
    
    func processDrop(providers: [NSItemProvider]) {
        Task {
            // 1. Extract URLs
            var urls: [URL] = []
            for provider in providers {
                if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }

            await accumulateFiles(urls)
        }
    }

    func accumulateFiles(_ urls: [URL]) async {
        // Expand folders
        var allFiles: [URL] = []
        for url in urls {
             if url.hasDirectoryPath {
                 if let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                     allFiles.append(contentsOf: children)
                 }
             } else {
                 allFiles.append(url)
             }
        }

        let gcsvFiles = allFiles.filter { $0.pathExtension.lowercased() == "gcsv" }
        let videoFiles = allFiles.filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }

        await MainActor.run {
            // Append new files (avoid duplicates)
            for file in gcsvFiles where !accumulatedGCSV.contains(file) {
                accumulatedGCSV.append(file)
            }
            for file in videoFiles where !accumulatedVideo.contains(file) {
                accumulatedVideo.append(file)
            }
        }
    }

    func chooseLensProfile() {
        let panel = NSOpenPanel()
        panel.title = "Select lens profile (.json)"
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            lensProfileURL = panel.url
        }
    }

    func clearAccumulatedFiles() {
        accumulatedGCSV.removeAll()
        accumulatedVideo.removeAll()
        processedFiles.removeAll()
    }

    func executeSync() async {
        isProcessing = true
        statusMessage = "Processing..."
        processedFiles.removeAll()

        await MainActor.run {
            totalProgress = accumulatedVideo.count
            currentProgress = 0
        }

        await processAccumulatedFiles()

        await MainActor.run {
            isProcessing = false
        }
    }
    
    func processAccumulatedFiles() async {
        let gcsvFiles = accumulatedGCSV
        let videoFiles = accumulatedVideo

        // 2. Parse GCSV (Build Master Timeline)
        var masterSamples: [GCSVSample] = []
        var header = ""

        for gcsv in gcsvFiles {
            if let samples = try? GCSVParser.parse(url: gcsv) {
                masterSamples.append(contentsOf: samples)
                if header.isEmpty {
                    header = (try? GCSVParser.getHeader(url: gcsv)) ?? ""
                }
            }
        }
        // Sort by timestamp
        masterSamples.sort { $0.timestamp < $1.timestamp }

        // 3. Determine batch IMU orientation. Priority:
        //   1. Advanced override (typed text field) — wins over everything
        //   2. iPhone standalone (no install_angle) → "XYZ" (IMU axes match
        //      camera axes on the same device, no remap needed)
        //   3. Connector-side preset → "ZYx" (right) or "zYX" (left)
        //
        // The connector-side preset only handles the discrete axis remap
        // (which side the USB-C/Lightning is on). Mount tilt (pitch/roll
        // for cases like phone-flat-on-top, phone-tilted-forward, phone-
        // vertical) is captured by install_angle in the gcsv header and
        // applied separately via gyro_source.rotation.
        //
        // v2.0-beta: removed the "DETECT" auto-detection path. Real-world
        // testing had guess_imu_orientation returning wrong values (e.g.
        // "xYZ" instead of "ZYx" for a USB-C-right mount), producing no
        // visible stabilization in DaVinci OFX. The connector-side preset
        // is the simple, reliable replacement.
        let masterContainsInstallAngle = GCSVParser.parseInstallAngle(fromHeader: header) != nil
        let isIphoneStandalone = header.contains("iPhone_Motion_Logger") && !masterContainsInstallAngle
        let override = imuOrientationOverride.trimmingCharacters(in: .whitespaces)
        let connectorPreset: String = (connectorSide == "left") ? "zYX" : "ZYx"
        let initialOrientationMode: String? = !override.isEmpty
            ? override
            : (isIphoneStandalone ? "XYZ" : connectorPreset)

        // Parse the manual RS override from the text field. Empty / non-positive
        // → no override, lens profile value (if any) is used by the helper.
        let rollingShutterMs: Double? = {
            let trimmed = rollingShutterMsText.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let v = Double(trimmed), v > 0 else { return nil }
            return v
        }()

        // 4. Process videos sequentially (sync is CPU intensive). Capture orientation
        // from the first clip's output so subsequent clips can skip detection.
        // Also collect a DirectReportRow per clip so we can write a per-folder
        // CSV report at the end of the batch.
        var batchOrientation: String? = nil
        var collectedRows: [DirectReportRow] = []
        for (i, video) in videoFiles.enumerated() {
            // First clip: use "DETECT" or "XYZ" per batch strategy.
            // Subsequent clips: force the orientation captured from clip 1 (or fall
            // back to initialOrientationMode if clip 1 didn't return anything).
            let orientationModeForThisClip: String? = (i == 0)
                ? initialOrientationMode
                : (batchOrientation ?? initialOrientationMode)
            let row = await self.processSingleVideo(
                video: video,
                masterSamples: masterSamples,
                header: header,
                imuOrientationMode: orientationModeForThisClip,
                lensProfilePath: lensProfileURL?.path,
                rollingShutterMs: rollingShutterMs
            )
            if let row = row {
                collectedRows.append(row)
                if batchOrientation == nil && !row.imuOrientationUsed.isEmpty {
                    batchOrientation = row.imuOrientationUsed
                    fputs("INFO: Batch orientation captured: \(row.imuOrientationUsed) (subsequent clips will reuse)\n", stderr)
                }
            }
        }

        // 5. Write per-folder CSV report so the user has a record of what was
        // processed, with what settings, and per-clip success/failure status.
        let installAngle = GCSVParser.parseInstallAngle(fromHeader: header)
        let session = DirectSessionInfo(
            generated: Date(),
            sourceGCSV: gcsvFiles.map { $0.lastPathComponent }.joined(separator: ", "),
            device: extractGcsvIdString(from: header),
            appVersion: "2.0-beta",
            imuOrientationBatch: batchOrientation ?? initialOrientationMode ?? "",
            installAngleRoll: Int(installAngle?.roll ?? 0),
            installAnglePitch: Int(installAngle?.pitch ?? 0),
            logRangeStart: Date(timeIntervalSince1970: masterSamples.first?.timestamp ?? 0),
            logRangeEnd: Date(timeIntervalSince1970: masterSamples.last?.timestamp ?? 0),
            timeScale: extractHeaderField(from: header, key: "tscale"),
            valueScale: extractHeaderField(from: header, key: "vscale"),
            note: extractHeaderField(from: header, key: "note"),
            timeOffsetApplied: timeOffset,
            sliceBuffer: 5.0,
            frameReadoutTimeMs: rollingShutterMs,
            lensProfileName: lensProfileURL?.lastPathComponent ?? ""
        )
        let writeResult = DirectReportWriter.writeGrouped(rows: collectedRows, session: session)
        await MainActor.run {
            for url in writeResult.written {
                processedFiles.append("Report: \(url.lastPathComponent)")
            }
            for err in writeResult.errors {
                processedFiles.append("Report Error: \(err)")
            }
            statusMessage = "Done! Processed \(videoFiles.count) videos."
        }
    }

    /// Pull a single-line `key,value` field from a GCSV header. Returns "" if
    /// the key is missing. Used to populate session metadata in the CSV report.
    private func extractHeaderField(from header: String, key: String) -> String {
        let pattern = #"(?m)^\#(key),(.+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: header)
        else { return "" }
        return String(header[r]).trimmingCharacters(in: .whitespaces)
    }

    private func extractGcsvIdString(from header: String) -> String {
        return extractHeaderField(from: header, key: "id")
    }

    /// Process a single video clip: timing fix, GCSV slice, .gyroflow generation.
    /// Returns a DirectReportRow describing what was done so the batch loop can
    /// (a) reuse `imuOrientationUsed` on subsequent clips to skip the slow ~90s
    /// detection pass, and (b) emit a per-folder CSV report at the end.
    /// Returns nil only if the video file can't be analyzed at all.
    func processSingleVideo(
        video: URL,
        masterSamples: [GCSVSample],
        header: String,
        imuOrientationMode: String? = nil,
        lensProfilePath: String? = nil,
        rollingShutterMs: Double? = nil
    ) async -> DirectReportRow? {
        defer {
            Task { @MainActor in
                currentProgress += 1
            }
        }

        // Fix ProRes RAW timing (VFR → CFR) — patches stts in-place
        var timingFixDescription = "n/a"
        if video.pathExtension.lowercased() == "mov" {
            let fixResult = ProResTimingFixer.fixIfNeeded(url: video)
            await MainActor.run {
                if fixResult.wasFixed {
                    processedFiles.append("Timing Fix: \(video.lastPathComponent) (\(fixResult.anomalousFrames) frames corrected)")
                } else if fixResult.message == "Already CFR" || fixResult.message == "No anomalies" {
                    processedFiles.append("Timing OK: \(video.lastPathComponent) (already CFR)")
                } else {
                    processedFiles.append("Timing: \(video.lastPathComponent) — \(fixResult.message)")
                }
            }
            timingFixDescription = fixResult.wasFixed
                ? "fixed (\(fixResult.anomalousFrames) frames)"
                : fixResult.message
        }

        guard let meta = await VideoProcessor.analyze(url: video) else {
            return nil
        }

        // Track the orientation actually written to .gyroflow so the batch loop
        // can capture and reuse it on subsequent clips.
        var writtenOrientation: String? = nil
        var gyroflowStatus = "skipped (no log data)"
        var statusOverall = "OK"
        var sliceStart: Date = meta.creationDate
        var sliceEnd: Date = meta.creationDate.addingTimeInterval(meta.duration)
        var sliceCount = 0
        var logCovered = "no log"
        let lensProfileName = lensProfilePath.map { ($0 as NSString).lastPathComponent } ?? ""

        let start = meta.startTime + timeOffset
        let end = meta.endTime + timeOffset

        // A. Process Logs
        if !masterSamples.isEmpty {
            // Slice with a buffer so that small camera-clock drift doesn't trim
            // away the actual motion window. Overlap between adjacent clips'
            // slices is harmless — each clip writes an independent .gcsv.
            let sliceBuffer: Double = 5.0
            let slice = masterSamples.filter { $0.timestamp >= (start - sliceBuffer) && $0.timestamp <= (end + sliceBuffer) }

            if !slice.isEmpty {
                sliceCount = slice.count
                sliceStart = Date(timeIntervalSince1970: slice.first?.timestamp ?? start)
                sliceEnd = Date(timeIntervalSince1970: slice.last?.timestamp ?? end)
                logCovered = "yes"

                // Export
                let newFileName = video.deletingPathExtension().appendingPathExtension("gcsv").lastPathComponent
                let folder = video.deletingLastPathComponent()
                let exportURL = folder.appendingPathComponent(newFileName)

                do {
                    try GCSVParser.export(samples: slice, to: exportURL, header: header)

                    // Set GCSV file creation date to match video
                    do {
                        try FileManager.default.setAttributes([.creationDate: meta.creationDate], ofItemAtPath: exportURL.path)
                        print("✅ Set GCSV file creation date to \(meta.creationDate)")
                    } catch {
                        print("⚠️ Failed to set GCSV file creation date: \(error)")
                    }

                    await MainActor.run {
                        processedFiles.append("Log Export: \(newFileName)")
                    }
                } catch {
                    print("Export error: \(error)")
                    statusOverall = "gcsv export failed"
                }

                // C. Generate .gyroflow file (bypass Gyroflow Desktop). Keep
                // output in the same folder as the source video so DaVinci OFX's
                // auto-load (which only searches the video's parent folder, see
                // gyroflow-plugins common/src/lib.rs::get_project_path) picks it
                // up without manual selection. When the user provided a manual
                // Rolling Shutter value, append `_RS{value}ms` to the filename
                // so re-runs at different RS values can coexist for comparison;
                // OFX's prefix-match still finds them, but if multiple RS variants
                // are present the user should delete the unwanted ones to make
                // auto-load deterministic.
                let baseName = video.deletingPathExtension().lastPathComponent
                let gyroflowExportURL: URL = {
                    if let rs = rollingShutterMs {
                        let rsLabel = String(format: "%g", rs)
                        return folder.appendingPathComponent("\(baseName)_RS\(rsLabel)ms.gyroflow")
                    } else {
                        return folder.appendingPathComponent("\(baseName).gyroflow")
                    }
                }()
                let gyroflowFileName = gyroflowExportURL.lastPathComponent

                var syncSucceeded = false
                do {
                    // Bias the search center to -5000ms to compensate for the slice
                    // buffer (GCSV is sliced ±5s around video, so true offset is
                    // around -5000ms when phone↔camera clocks are synced). This
                    // puts the iPhone "perfectly synced" case at the center of the
                    // search range, instead of the edge.
                    //   center = -5000 + (user's clock-drift override)
                    //   range  = [-10000, 0] when user override = 0
                    let sliceBufferOffsetMs: Double = -5000.0
                    let effectiveInitialOffsetMs = (timeOffset * 1000.0) + sliceBufferOffsetMs

                    let detectedOrientation = try await GyroflowProcessor.syncInSubprocess(
                        videoPath: video.path,
                        gcsvPath: exportURL.path,
                        outputPath: gyroflowExportURL.path,
                        lensProfilePath: lensProfilePath,
                        initialOffsetMs: effectiveInitialOffsetMs,
                        searchSizeMs: gyroflowSearchSize,
                        imuOrientationMode: imuOrientationMode,
                        frameReadoutTimeMs: rollingShutterMs
                    )
                    writtenOrientation = detectedOrientation
                    syncSucceeded = true
                    gyroflowStatus = "OK"
                    await MainActor.run {
                        let orientLabel = detectedOrientation.map { " (orientation: \($0))" } ?? ""
                        processedFiles.append("Gyroflow: \(gyroflowFileName)\(orientLabel)")
                    }

                    // Surface install_angle detection (auto-applied by helper into gyro_source.rotation)
                    if let headerText = try? GCSVParser.getHeader(url: exportURL),
                       let angle = GCSVParser.parseInstallAngle(fromHeader: headerText) {
                        let rStr = String(format: "%+d", Int(angle.roll))
                        let pStr = String(format: "%+d", Int(angle.pitch))
                        await MainActor.run {
                            processedFiles.append("Detected install angle: R\(rStr)° P\(pStr)° (auto-applied)")
                        }
                    }
                } catch {
                    print("Gyroflow subprocess sync failed: \(error), falling back to timestamp-based export")
                    gyroflowStatus = "fallback (sync failed: \(error.localizedDescription))"
                }

                if !syncSucceeded {
                    do {
                        let fallbackProcessor = try GyroflowProcessor()
                        try await fallbackProcessor.timestampExport(
                            videoPath: video.path,
                            gcsvPath: exportURL.path,
                            outputPath: gyroflowExportURL.path,
                            offsetMs: timeOffset * 1000.0
                        )

                        // Fallback path doesn't go through the helper subprocess, so
                        // install_angle injection has to happen here.
                        injectInstallAngleIntoGyroflow(gcsvPath: exportURL.path, gyroflowPath: gyroflowExportURL.path)
                        writtenOrientation = "ZYx"  // fallback path hardcodes ZYx
                        gyroflowStatus = "fallback OK"

                        await MainActor.run {
                            processedFiles.append("Gyroflow (fallback): \(gyroflowFileName)")
                        }

                        if let headerText = try? GCSVParser.getHeader(url: exportURL),
                           let angle = GCSVParser.parseInstallAngle(fromHeader: headerText) {
                            let rStr = String(format: "%+d", Int(angle.roll))
                            let pStr = String(format: "%+d", Int(angle.pitch))
                            await MainActor.run {
                                processedFiles.append("Detected install angle: R\(rStr)° P\(pStr)° (auto-applied, fallback)")
                            }
                        }
                    } catch {
                        print("Gyroflow timestamp export also failed: \(error)")
                        gyroflowStatus = "FAILED: \(error.localizedDescription)"
                        statusOverall = "gyroflow generation failed"
                        await MainActor.run {
                            processedFiles.append("Gyroflow Error: \(error.localizedDescription)")
                        }
                    }
                }
            } else {
                print("No overlapping data for video: \(video.lastPathComponent)")
                logCovered = "no overlap"
                gyroflowStatus = "skipped (no log overlap)"
                statusOverall = "no log overlap"
                await MainActor.run {
                    processedFiles.append("Log No overlap: \(video.lastPathComponent)")
                }
            }
        }

        return DirectReportRow(
            videoURL: video,
            videoStart: meta.creationDate,
            videoEnd: meta.creationDate.addingTimeInterval(meta.duration),
            duration: meta.duration,
            logSliceStart: sliceStart,
            logSliceEnd: sliceEnd,
            logSamples: sliceCount,
            logCovered: logCovered,
            timingFix: timingFixDescription,
            timeOffsetApplied: timeOffset,
            imuOrientationUsed: writtenOrientation ?? "",
            frameReadoutTimeMs: rollingShutterMs,
            lensProfileName: lensProfileName,
            syncOffsetMs: nil,  // not currently surfaced from helper subprocess
            gyroflowStatus: gyroflowStatus,
            status: statusOverall
        )
    }

    // On the fallback (timestamp-only) export path we skip the helper subprocess,
    // so install_angle from the gcsv note never gets written to gyro_source.rotation.
    // Patch the .gyroflow JSON in place so Gyroflow opens with pitch/roll pre-applied.
    func injectInstallAngleIntoGyroflow(gcsvPath: String, gyroflowPath: String) {
        let gcsvURL = URL(fileURLWithPath: gcsvPath)
        let headerText = try? GCSVParser.getHeader(url: gcsvURL)
        let angle = headerText.flatMap { GCSVParser.parseInstallAngle(fromHeader: $0) }
        do {
            let gyroflowURL = URL(fileURLWithPath: gyroflowPath)
            let data = try Data(contentsOf: gyroflowURL)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var gyroSource = (json["gyro_source"] as? [String: Any]) ?? [:]
            if let angle = angle {
                gyroSource["rotation"] = [angle.pitch, angle.roll, 0.0]
            }
            gyroSource["imu_orientation"] = "ZYx"
            json["gyro_source"] = gyroSource
            json["offsets"] = [String: Any]()
            let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try updated.write(to: gyroflowURL)
        } catch {
            print("Failed to post-process fallback .gyroflow: \(error)")
        }
    }

}
