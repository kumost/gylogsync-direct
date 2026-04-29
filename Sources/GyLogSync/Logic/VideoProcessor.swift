// VideoProcessor.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

import Foundation
import AVFoundation

struct VideoFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let creationDate: Date
    let duration: TimeInterval
    
    // Calculated timestamps
    // Note: creationDate represents the START time of recording
    var startTime: TimeInterval { creationDate.timeIntervalSince1970 }
    var endTime: TimeInterval { startTime + duration }
}

class VideoProcessor {
    static func analyze(url: URL) async -> VideoFile? {
        let asset = AVURLAsset(url: url)
        
        do {
            let duration = try await asset.load(.duration).seconds
            
            // Try to get date from Metadata
            var creationDate: Date?
            var method = ""

            let resources = try? url.resourceValues(forKeys: [.creationDateKey])
            let fileSystemCreationDate = resources?.creationDate

            // 1. PRIORITY: Try asset.creationDate property (works for Sony cameras)
            if let creationItem = try await asset.load(.creationDate),
               let dateValue = try? await creationItem.load(.dateValue) {
                creationDate = dateValue
                method = "asset.creationDate"
            }

            // 2. Fallback: Common Metadata (for other formats)
            if creationDate == nil {
                let commonMetadata = try await asset.load(.commonMetadata)
                for item in commonMetadata {
                     if item.commonKey == .commonKeyCreationDate {
                         if let dateValue = try? await item.load(.value) as? Date {
                             creationDate = dateValue
                             method = "commonKeyCreationDate (Date)"
                             break
                         }
                         if let dateString = try? await item.load(.value) as? String {
                             if let date = ISO8601DateFormatter().date(from: dateString) {
                                 creationDate = date
                                 method = "commonKeyCreationDate (String)"
                                 break
                             }
                         }
                     }
                }
            }

            // 3. Magic Lantern exports often lose MOV creation_time. If a same-
            // named original MLV exists nearby, prefer its filesystem timestamp.
            if creationDate == nil,
               let mlvDate = pairedMagicLanternMlvCreationDate(for: url, duration: duration) {
                creationDate = mlvDate
                method = "paired MLV file creation date"
            }

            // 4. Last Resort: File System Attributes
            if creationDate == nil {
                print("⚠️ Metadata date not found for \(url.lastPathComponent). Using file system date.")
                creationDate = fileSystemCreationDate
                method = "file system (FALLBACK)"
            }
            
            let correction = correctedCameraDateIfNeeded(
                metadataDate: creationDate,
                fileSystemCreationDate: fileSystemCreationDate
            )
            let finalDate = correction.date ?? creationDate ?? Date()
            if correction.wasCorrected {
                method += " + local-time metadata correction"
            }
            print("Video: \(url.lastPathComponent) -> Date: \(finalDate) [\(method)]")
            
            return VideoFile(url: url, name: url.lastPathComponent, creationDate: finalDate, duration: duration)
        } catch {
            print("Error processing video \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private static func correctedCameraDateIfNeeded(
        metadataDate: Date?,
        fileSystemCreationDate: Date?
    ) -> (date: Date?, wasCorrected: Bool) {
        guard let metadataDate, let fileSystemCreationDate else {
            return (metadataDate, false)
        }

        // Some cameras write local wall-clock time into QuickTime creation_time,
        // which AVFoundation exposes as UTC. If subtracting the local GMT offset
        // makes metadata line up with the filesystem creation date, use it.
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: metadataDate))
        guard abs(offset) > 0 else {
            return (metadataDate, false)
        }

        let corrected = metadataDate.addingTimeInterval(-offset)
        let originalDelta = abs(metadataDate.timeIntervalSince(fileSystemCreationDate))
        let correctedDelta = abs(corrected.timeIntervalSince(fileSystemCreationDate))
        let offsetMagnitude = abs(offset)

        if abs(originalDelta - offsetMagnitude) <= 180,
           correctedDelta <= 180,
           correctedDelta + 60 < originalDelta {
            print("🕒 Corrected local-time camera metadata: \(metadataDate) -> \(corrected) (filesystem: \(fileSystemCreationDate), offset: \(offset))")
            return (corrected, true)
        }

        return (metadataDate, false)
    }

    private static func pairedMagicLanternMlvCreationDate(
        for url: URL,
        duration: TimeInterval
    ) -> Date? {
        let fileManager = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent()

        let candidates = [
            folder.appendingPathComponent(baseName).appendingPathExtension("MLV"),
            folder.appendingPathComponent(baseName).appendingPathExtension("mlv"),
            parent.appendingPathComponent(baseName).appendingPathExtension("MLV"),
            parent.appendingPathComponent(baseName).appendingPathExtension("mlv")
        ]

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            guard let resources = try? candidate.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) else {
                continue
            }

            if let creationDate = resources.creationDate {
                print("🎞️ Using paired MLV timestamp for \(url.lastPathComponent): \(candidate.lastPathComponent) -> \(creationDate)")
                return creationDate
            }

            if let modifiedDate = resources.contentModificationDate, duration.isFinite, duration > 0 {
                let estimatedStart = modifiedDate.addingTimeInterval(-duration)
                print("🎞️ Estimated MLV start from modification date for \(url.lastPathComponent): \(candidate.lastPathComponent) -> \(estimatedStart)")
                return estimatedStart
            }
        }

        return nil
    }

    /// Detect lens type from Blackmagic Camera MOV metadata.
    /// Reads `com.blackmagic-design.camera.lensType` tag (e.g. "iPhone 17 Pro 24mm").
    /// Returns the focal length string ("13mm", "24mm", "100mm") or nil.
    static func detectLens(url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata {
                if let key = item.commonKey?.rawValue, key == "make" { continue }
                guard let identifier = item.identifier else { continue }
                let idStr = identifier.rawValue

                // Blackmagic writes lens info in quicktime metadata
                if idStr.contains("lensType") || idStr.contains("model") {
                    if let value = try? await item.load(.value) as? String {
                        // Extract focal length: "iPhone 17 Pro 24mm" → "24mm"
                        if let range = value.range(of: #"\d+mm"#, options: .regularExpression) {
                            let focalLength = String(value[range])
                            print("Detected lens for \(url.lastPathComponent): \(value) → \(focalLength)")
                            return focalLength
                        }
                    }
                }
            }
        } catch {
            print("Lens detection error for \(url.lastPathComponent): \(error)")
        }
        return nil
    }
}
