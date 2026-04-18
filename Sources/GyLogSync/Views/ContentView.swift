// ContentView.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @State private var statusMessage = "Drag & Drop a Folder containing .gcsv, Audio, and Videos."
    @State private var isProcessing = false
    @State private var processedFiles: [String] = []
    @State private var timeOffset: Double = 0.0
    @State private var showAdvanced = false

    // New: Accumulated files for staged processing
    @State private var accumulatedGCSV: [URL] = []
    @State private var accumulatedAudio: [URL] = []
    @State private var accumulatedVideo: [URL] = []

    // Progress tracking
    @State private var currentProgress: Int = 0
    @State private var totalProgress: Int = 0

    // Audio processing option
    @State private var skipAudioProcessing = false

    // Gyroflow processing options
    @State private var gyroflowSearchSize: Double = 500

    // Built-in lens profile options (iPhone 17 Pro)
    enum LensOption: String, CaseIterable {
        case lens24mm = "17 Pro - 24mm (Wide 1x)"
        case none = "None (Manual)"

        var filename: String? {
            switch self {
            case .lens24mm: return "iPhone17pro_24mm.json"
            case .none: return nil
            }
        }
    }
    @State private var selectedLens: LensOption = .none

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
                                Label("\(accumulatedAudio.count)", systemImage: "waveform")
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
                    .disabled(accumulatedGCSV.isEmpty && accumulatedVideo.isEmpty && accumulatedAudio.isEmpty)

                    Button(action: { Task { await executeSync() } }) {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accumulatedVideo.isEmpty || (accumulatedGCSV.isEmpty && accumulatedAudio.isEmpty) || isProcessing)
                }
                .padding(.horizontal)

                // Advanced Options
                DisclosureGroup("Advanced Options", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Skip Audio Toggle
                        Toggle(isOn: $skipAudioProcessing) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Skip Audio Processing")
                                    .font(.body)
                                Text("Only process video logs (faster)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        // Time Offset
                        HStack {
                            Text("Time Offset (sec):")
                            TextField("0.0", value: $timeOffset, formatter: NumberFormatter())
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                            Stepper("", value: $timeOffset, in: -86400...86400, step: 0.5)
                            Text(timeOffset > 0 ? "(Camera is ahead)" : timeOffset < 0 ? "(Camera is behind)" : "(No offset)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        // Gyroflow Options
                        HStack {
                            Text("Sync search range (ms):")
                            TextField("500", value: $gyroflowSearchSize, formatter: NumberFormatter())
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("Lens profile:")
                            Picker("", selection: $selectedLens) {
                                ForEach(LensOption.allCases, id: \.self) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .frame(width: 280)
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

                        if !accumulatedAudio.isEmpty {
                            Section(header: Text("Audio (\(accumulatedAudio.count))").font(.caption2)) {
                                ForEach(accumulatedAudio, id: \.self) { file in
                                    HStack {
                                        Image(systemName: "waveform")
                                        Text(file.lastPathComponent)
                                            .font(.system(.caption2, design: .monospaced))
                                        Spacer()
                                    }
                                }
                            }
                        }

                        if accumulatedGCSV.isEmpty && accumulatedVideo.isEmpty && accumulatedAudio.isEmpty {
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
        let audioFiles = allFiles.filter { ["m4a", "wav", "mp3", "m4b"].contains($0.pathExtension.lowercased()) }
        let videoFiles = allFiles.filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }

        await MainActor.run {
            // Append new files (avoid duplicates)
            for file in gcsvFiles where !accumulatedGCSV.contains(file) {
                accumulatedGCSV.append(file)
            }
            for file in audioFiles where !accumulatedAudio.contains(file) {
                accumulatedAudio.append(file)
            }
            for file in videoFiles where !accumulatedVideo.contains(file) {
                accumulatedVideo.append(file)
            }
        }
    }

    func clearAccumulatedFiles() {
        accumulatedGCSV.removeAll()
        accumulatedAudio.removeAll()
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
        let audioFiles = skipAudioProcessing ? [] : accumulatedAudio
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

        // 3. Process Videos sequentially (gyroflow sync is CPU/GPU intensive)
        for video in videoFiles {
            await self.processSingleVideo(video: video, masterSamples: masterSamples, header: header, audioFiles: audioFiles)
        }

        await MainActor.run {
            statusMessage = "Done! Processed \(videoFiles.count) videos."
        }
    }

    func processSingleVideo(video: URL, masterSamples: [GCSVSample], header: String, audioFiles: [URL]) async {
        defer {
            Task { @MainActor in
                currentProgress += 1
            }
        }

        // Fix ProRes RAW timing (VFR → CFR) — patches stts in-place
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
        }

        guard let meta = await VideoProcessor.analyze(url: video) else {
            return
        }

        let start = meta.startTime + timeOffset
        let end = meta.endTime + timeOffset

        // A. Process Logs
        if !masterSamples.isEmpty {
            // Slice
            let slice = masterSamples.filter { $0.timestamp >= start && $0.timestamp <= end }

            if !slice.isEmpty {
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
                }

                // C. Generate .gyroflow file (bypass Gyroflow Desktop)
                let gyroflowFileName = video.deletingPathExtension().appendingPathExtension("gyroflow").lastPathComponent
                let gyroflowExportURL = folder.appendingPathComponent(gyroflowFileName)
                let lens = resolvedLensProfilePath()

                var syncSucceeded = false
                do {
                    try await GyroflowProcessor.syncInSubprocess(
                        videoPath: video.path,
                        gcsvPath: exportURL.path,
                        outputPath: gyroflowExportURL.path,
                        lensProfilePath: lens,
                        initialOffsetMs: timeOffset * 1000.0,
                        searchSizeMs: gyroflowSearchSize
                    )
                    syncSucceeded = true
                    await MainActor.run {
                        processedFiles.append("Gyroflow: \(gyroflowFileName)")
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
                }

                if !syncSucceeded {
                    do {
                        let fallbackProcessor = try GyroflowProcessor()
                        try await fallbackProcessor.timestampExport(
                            videoPath: video.path,
                            gcsvPath: exportURL.path,
                            outputPath: gyroflowExportURL.path,
                            lensProfilePath: lens,
                            offsetMs: timeOffset * 1000.0
                        )
                        await MainActor.run {
                            processedFiles.append("Gyroflow (fallback): \(gyroflowFileName)")
                        }
                    } catch {
                        print("Gyroflow timestamp export also failed: \(error)")
                        await MainActor.run {
                            processedFiles.append("Gyroflow Error: \(error.localizedDescription)")
                        }
                    }
                }
            } else {
                print("No overlapping data for video: \(video.lastPathComponent)")
                await MainActor.run {
                    processedFiles.append("Log No overlap: \(video.lastPathComponent)")
                }
            }
        }

        // B. Process Audio (skip if disabled)
        if !audioFiles.isEmpty {
            for audio in audioFiles {
                     // Prevent Video splitting itself if it's also detected as audio (mp4)
                     if audio == video { continue }
                     
                     // Get Audio Creation Date (as fallback or reference for Year)
                     if let resources = try? audio.resourceValues(forKeys: [.creationDateKey]),
                        let audioFileDate = resources.creationDate {
                         
                         var audioStartAbs = audioFileDate.timeIntervalSince1970
                         
                         // Try to parse filename for more accurate Start Time (GyLog format)
                         // Filename: GyLog_MMDD_HHMMSS.m4a  (e.g. GyLog_1226_125935)
                         let filename = audio.deletingPathExtension().lastPathComponent
                         if let parsedDate = parseGyLogTimestamp(filename: filename, referenceDate: audioFileDate) {
                             audioStartAbs = parsedDate.timeIntervalSince1970
                             print("Parsed Audio Date from Filename: \(parsedDate)")
                         } else {
                             // If creation date is End Time (common in audio), we might need to subtract duration?
                             // But only if we are SURE. For random files, Creation Date is typical Start.
                             // Let's rely on filename primarily.
                         }

                         // Audio Absolute Time Range
                         let audioAsset = AVURLAsset(url: audio)
                         let audioDuration = CMTimeGetSeconds(audioAsset.duration)
                         let audioEndAbs = audioStartAbs + audioDuration
                         
                         // Video Absolute Time Range (from 'start' and 'end' calc above)
                         // start = VideoStart + Offset
                         // end = VideoEnd + Offset
                         
                         // Intersection
                         let overlapStart = max(start, audioStartAbs)
                         let overlapEnd = min(end, audioEndAbs)
                         
                         if overlapEnd > overlapStart {
                             // Valid overlap
                             // Convert absolute overlap to relative audio time
                             let trimStart = overlapStart - audioStartAbs
                             let trimDuration = overlapEnd - overlapStart
                             
                             // Standardize filename: VideoName.m4a (omit source audio name)
                             let newFileName = video.deletingPathExtension().appendingPathExtension(audio.pathExtension).lastPathComponent
                             let folder = video.deletingLastPathComponent()
                             let exportURL = folder.appendingPathComponent(newFileName)
                             
                             do {
                                 // Note: trimDuration might be shorter than video duration if partial overlap
                                 // Set audio file creation date to match video
                                 try await AudioTrimmer.trimAudio(sourceURL: audio, destinationURL: exportURL, startTime: trimStart, duration: trimDuration, targetCreationDate: meta.creationDate)

                                 // Add status feedback about partial overlap if significant
                                 let isPartial = (trimDuration < meta.duration - 0.5)
                                 let note = isPartial ? " (Partial)" : ""
                                 
                                 await MainActor.run {
                                     processedFiles.append("Audio Export: \(newFileName)\(note)")
                                 }
                             } catch {
                                 print("Audio trim error: \(error)")
                                 await MainActor.run {
                                     processedFiles.append("Audio Error: \(error.localizedDescription)")
                                 }
                             }
                         } else {
                             // No intersection
                              let vStartStr = Date(timeIntervalSince1970: start).formatted(date: .omitted, time: .standard)
                              let aStartStr = Date(timeIntervalSince1970: audioStartAbs).formatted(date: .omitted, time: .standard)
                              
                              await MainActor.run {
                                 processedFiles.append("No overlap: Video(\(vStartStr)) vs Audio(\(aStartStr))")
                                 processedFiles.append("Diff: \(audioStartAbs - start) sec")
                              }
                         }
                }
            }
        }
    }
    
    // Resolve lens profile path from selected option
    func resolvedLensProfilePath() -> String? {
        guard let filename = selectedLens.filename else { return nil }
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let resourcesDir = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("LensProfiles")
            .appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: resourcesDir.path) {
            return resourcesDir.path
        }
        let nextToExe = execURL
            .deletingLastPathComponent()
            .appendingPathComponent("LensProfiles")
            .appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: nextToExe.path) {
            return nextToExe.path
        }
        print("WARNING: Built-in lens profile not found: \(filename)")
        return nil
    }

    // Helper to extract date from GyLog_MMDD_HHMMSS
    func parseGyLogTimestamp(filename: String, referenceDate: Date) -> Date? {
        // Simple regex or string parsing
        // Target: GyLog_1226_125935
        let parts = filename.components(separatedBy: "_")
        if parts.count >= 3, parts[0] == "GyLog", parts[1].count == 4, parts[2].count == 6 {
            let mmdd = parts[1]
            let hhmmss = parts[2]
            
            let calendar = Calendar.current
            let year = calendar.component(.year, from: referenceDate)
            
            var components = DateComponents()
            components.year = year
            components.month = Int(mmdd.prefix(2))
            components.day = Int(mmdd.suffix(2))
            components.hour = Int(hhmmss.prefix(2))
            components.minute = Int(hhmmss.dropFirst(2).prefix(2))
            components.second = Int(hhmmss.suffix(2))
            
            return calendar.date(from: components)
        }
        return nil
    }
}
