// AudioTrimmer.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/GyLogSync

import Foundation
import AVFoundation

class AudioTrimmer {
    
    enum TrimmerError: Error {
        case exportSessionFailed
        case outputURLAlreadyExists
    }
    
    static func trimAudio(sourceURL: URL, destinationURL: URL, startTime: TimeInterval, duration: TimeInterval, targetCreationDate: Date? = nil) async throws {
        let asset = AVAsset(url: sourceURL)
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TrimmerError.exportSessionFailed
        }
        
        // Remove existing file if necessary
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        exportSession.outputURL = destinationURL
        
        // Determine output file type based on extension
        let ext = destinationURL.pathExtension.lowercased()
        switch ext {
        case "m4a":
            exportSession.outputFileType = .m4a
        case "wav":
            exportSession.outputFileType = .wav
        case "mp3":
            // AVAssetExportPresetPassthrough might not work for mp3 if container is different, 
            // but core audio usually handles it. If not, we might need a re-encoding preset.
            // For now, try core audio type.
            exportSession.outputFileType = .mp3 // Requires macOS 10.13+
        default:
            exportSession.outputFileType = .m4a // Fallback
        }
        
        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: start, duration: duration.toCMTime())
        
        exportSession.timeRange = timeRange
        
        await exportSession.export()
        
        switch exportSession.status {
        case .completed:
            // Fix file creation date to match video
            if let creationDate = targetCreationDate {
                try await fixFileCreationDate(url: destinationURL, date: creationDate)
                // Also set file system creation date for compatibility
                try setFileSystemCreationDate(url: destinationURL, date: creationDate)
            }
            return
        case .failed:
            throw exportSession.error ?? TrimmerError.exportSessionFailed
        case .cancelled:
            throw TrimmerError.exportSessionFailed
        default:
            throw TrimmerError.exportSessionFailed
        }
    }

    // Set file system creation date to match video
    private static func setFileSystemCreationDate(url: URL, date: Date) throws {
        do {
            try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
            print("✅ Set file system creation date to \(date)")
        } catch {
            print("⚠️ Failed to set file system creation date: \(error)")
            // Don't throw - this is not critical
        }
    }

    // Fix file creation date to match video timestamp using ffmpeg
    private static func fixFileCreationDate(url: URL, date: Date) async throws {
        print("🔧 Attempting to fix audio file metadata...")
        print("   File: \(url.lastPathComponent)")
        print("   Target date: \(date)")

        // Find ffmpeg executable
        let ffmpegPath = findFFmpeg()
        guard let ffmpegPath = ffmpegPath else {
            print("⚠️ ffmpeg not found - skipping metadata fix")
            print("   Install ffmpeg with: brew install ffmpeg")
            return  // Don't fail, just skip metadata fix
        }

        print("   Using ffmpeg: \(ffmpegPath)")

        // Format date for ffmpeg (ISO8601 format)
        let formatter = ISO8601DateFormatter()
        let dateString = formatter.string(from: date)

        // Create temporary file
        let tempURL = url.deletingLastPathComponent().appendingPathComponent("temp_\(url.lastPathComponent)")

        // Remove temp file if exists
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }

        // Use ffmpeg to copy audio with new metadata
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-i", url.path,
            "-c", "copy",  // Copy without re-encoding
            "-metadata", "creation_time=\(dateString)",
            "-y",  // Overwrite output file
            tempURL.path
        ]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                // Replace original with temp file
                try FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tempURL, to: url)
                print("✅ Fixed audio file metadata successfully to \(dateString)")
            } else {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                print("❌ ffmpeg failed (exit code \(process.terminationStatus))")
                print("   \(errorString.prefix(200))")
                // Clean up temp file
                try? FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            print("❌ Failed to run ffmpeg: \(error)")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    // Find ffmpeg executable in common locations
    private static func findFFmpeg() -> String? {
        let possiblePaths = [
            "/opt/homebrew/bin/ffmpeg",  // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg",     // Intel Homebrew
            "/opt/local/bin/ffmpeg",     // MacPorts
            "/usr/bin/ffmpeg"            // System
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try using 'which' command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {
            // Ignore error
        }

        return nil
    }
}

extension TimeInterval {
    func toCMTime() -> CMTime {
        return CMTime(seconds: self, preferredTimescale: 600)
    }
}
