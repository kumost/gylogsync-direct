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

            // 1. PRIORITY: Try asset.creationDate property (works for Sony cameras)
            if let assetCreationDate = try? await asset.load(.creationDate)?.dateValue {
                creationDate = assetCreationDate
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

            // 3. Last Resort: File System Attributes
            if creationDate == nil {
                print("⚠️ Metadata date not found for \(url.lastPathComponent). Using file system date.")
                let resources = try url.resourceValues(forKeys: [.creationDateKey])
                creationDate = resources.creationDate
                method = "file system (FALLBACK)"
            }
            
            let finalDate = creationDate ?? Date()
            print("Video: \(url.lastPathComponent) -> Date: \(finalDate) [\(method)]")
            
            return VideoFile(url: url, name: url.lastPathComponent, creationDate: finalDate, duration: duration)
        } catch {
            print("Error processing video \(url.lastPathComponent): \(error)")
            return nil
        }
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
