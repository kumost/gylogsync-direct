// ProResTimingFixer.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

import Foundation

/// Fixes variable frame timing (stts atom) in ProRes RAW MOV files
/// recorded by the Blackmagic Camera app on iPhone.
///
/// The fix modifies ONLY the stts atom in the MOV container (a few bytes
/// of timing metadata). Video and audio data are never touched.
///
/// Safety: before any byte is changed, the source file is cloned to
/// `<file>.MOV.prev` (an O(1) APFS clone on local volumes; a full copy on
/// SMB/NFS). On successful write+sync+size-verify, the .prev is deleted.
/// On any failure mid-process the .prev is retained so the user can
/// restore the original by renaming it back.
class ProResTimingFixer {

    struct FixResult {
        let filename: String
        let totalFrames: Int
        let anomalousFrames: Int
        let wasFixed: Bool
        let message: String
    }

    /// Inspect and fix the stts atom in-place if VFR is detected.
    /// Modifies only a few bytes of timing metadata in the container.
    static func fixIfNeeded(url: URL) -> FixResult {
        let filename = url.lastPathComponent

        guard url.pathExtension.lowercased() == "mov" else {
            return FixResult(filename: filename, totalFrames: 0, anomalousFrames: 0,
                           wasFixed: false, message: "Not a MOV file")
        }

        guard FileManager.default.isWritableFile(atPath: url.path) else {
            return FixResult(filename: filename, totalFrames: 0, anomalousFrames: 0,
                           wasFixed: false, message: "File is not writable")
        }

        let backupURL = url.appendingPathExtension("prev")
        var backupCreated = false

        // Build a failure FixResult that mentions the surviving backup so the
        // user knows where to restore from. Reads `backupCreated` at call
        // time so it reflects the latest state.
        func failure(_ message: String, totalFrames: Int = 0, anomalousFrames: Int = 0) -> FixResult {
            let suffix = backupCreated ? " — backup retained: \(backupURL.lastPathComponent)" : ""
            return FixResult(filename: filename, totalFrames: totalFrames,
                             anomalousFrames: anomalousFrames,
                             wasFixed: false, message: message + suffix)
        }

        do {
            let fileHandle = try FileHandle(forUpdating: url)
            defer { try? fileHandle.close() }

            let fileSize = fileHandle.seekToEndOfFile()
            guard fileSize >= 8 else {
                return FixResult(filename: filename, totalFrames: 0, anomalousFrames: 0,
                               wasFixed: false, message: "File too small")
            }

            // 1. Find moov atom
            guard let (moovOffset, moovSize) = findMoovAtom(fileHandle: fileHandle, fileSize: fileSize) else {
                return FixResult(filename: filename, totalFrames: 0, anomalousFrames: 0,
                               wasFixed: false, message: "No moov atom found")
            }

            // 2. Find video track's stts using proper atom traversal
            guard let sttsOffset = findVideoStts(fileHandle: fileHandle, moovOffset: moovOffset, moovSize: moovSize) else {
                return FixResult(filename: filename, totalFrames: 0, anomalousFrames: 0,
                               wasFixed: false, message: "No video stts found")
            }

            // 3. Analyze stts
            guard let sttsInfo = analyzeStts(fileHandle: fileHandle, sttsOffset: sttsOffset) else {
                return FixResult(filename: filename, totalFrames: 0, anomalousFrames: 0,
                               wasFixed: false, message: "Failed to parse stts")
            }

            // 4. Check if fix is needed (early-return paths skip the backup, so
            //    no .prev clutter for already-CFR files)
            if sttsInfo.entryCount <= 1 {
                return FixResult(filename: filename, totalFrames: sttsInfo.totalSamples, anomalousFrames: 0,
                               wasFixed: false, message: "Already CFR")
            }

            let anomalousFrames = sttsInfo.entries
                .filter { $0.delta != sttsInfo.dominantDelta }
                .reduce(0) { $0 + $1.count }

            if anomalousFrames == 0 {
                return FixResult(filename: filename, totalFrames: sttsInfo.totalSamples, anomalousFrames: 0,
                               wasFixed: false, message: "No anomalies")
            }

            guard sttsInfo.totalSamples > 0, sttsInfo.totalSamples <= Int(UInt32.max) else {
                return FixResult(filename: filename, totalFrames: sttsInfo.totalSamples, anomalousFrames: anomalousFrames,
                               wasFixed: false, message: "Invalid sample count")
            }

            // 5. Verify file size before modification
            let originalFileSize = fileHandle.seekToEndOfFile()

            // 6. Create the .prev backup. APFS uses copy-on-write (clonefile)
            //    so this is O(1) and uses ~0 additional space until the
            //    original diverges; on SMB/NFS this is a full copy.
            //    Delete any leftover .prev from a previous run first.
            let fm = FileManager.default
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            try fm.copyItem(at: url, to: backupURL)
            backupCreated = true

            // 7. Write fix: single stts entry with uniform delta.
            //    Layout: size(4) + 'stts'(4) + version+flags(4) + entry_count(4) + entries(N*8)
            try fileHandle.seek(toOffset: UInt64(sttsOffset + 12))

            let entryCount: UInt32 = 1
            let sampleCount: UInt32 = UInt32(sttsInfo.totalSamples)
            let sampleDelta: UInt32 = UInt32(sttsInfo.dominantDelta)

            var data = Data()
            data.append(contentsOf: withUnsafeBytes(of: entryCount.bigEndian) { Array($0) })
            data.append(contentsOf: withUnsafeBytes(of: sampleCount.bigEndian) { Array($0) })
            data.append(contentsOf: withUnsafeBytes(of: sampleDelta.bigEndian) { Array($0) })

            try fileHandle.write(contentsOf: data)

            // Zero out remaining entry space (overwrite old entries, no file size change)
            let remainingBytes = (sttsInfo.entryCount - 1) * 8
            if remainingBytes > 0 {
                try fileHandle.write(contentsOf: Data(count: remainingBytes))
            }

            // Flush to disk so the in-memory page cache hits stable storage
            // before we declare success.
            try fileHandle.synchronize()

            // 8. Verify file size unchanged (we only overwrote bytes, never appended/truncated)
            let newFileSize = fileHandle.seekToEndOfFile()
            if newFileSize != originalFileSize {
                // Treat as failure — keep the backup so the user can recover.
                return failure("File size changed from \(originalFileSize) to \(newFileSize)",
                               totalFrames: sttsInfo.totalSamples,
                               anomalousFrames: anomalousFrames)
            }

            print("Fixed stts: \(filename) — \(anomalousFrames) of \(sttsInfo.totalSamples) frames corrected to uniform \(sttsInfo.dominantDelta)-tick delta")

            // 9. Success — remove the backup.
            try? fm.removeItem(at: backupURL)
            backupCreated = false

            return FixResult(filename: filename, totalFrames: sttsInfo.totalSamples,
                           anomalousFrames: anomalousFrames, wasFixed: true,
                           message: "\(anomalousFrames) frames fixed")

        } catch {
            // Anything thrown by FileHandle / FileManager lands here. The
            // .prev (if created) is intentionally retained so the user can
            // restore by renaming it back over the original.
            return failure("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private helpers

    private struct SttsEntry {
        let count: Int
        let delta: Int
    }

    private struct SttsInfo {
        let offset: Int
        let size: Int
        let entryCount: Int
        let entries: [SttsEntry]
        let totalSamples: Int
        let dominantDelta: Int
    }

    /// Find the moov atom by walking top-level atoms
    private static func findMoovAtom(fileHandle: FileHandle, fileSize: UInt64) -> (Int, Int)? {
        var pos: UInt64 = 0

        while pos + 8 <= fileSize {
            fileHandle.seek(toFileOffset: pos)
            let headerData = fileHandle.readData(ofLength: 8)
            guard headerData.count == 8 else { break }

            let size = UInt64(readUInt32BE(headerData, offset: 0))
            let atomType = String(data: headerData[4..<8], encoding: .ascii) ?? ""

            var actualSize = size
            if size == 1 {
                let extData = fileHandle.readData(ofLength: 8)
                guard extData.count == 8 else { break }
                actualSize = readUInt64BE(extData, offset: 0)
            }

            guard actualSize >= 8 else { break }

            if atomType == "moov" {
                return (Int(pos), Int(actualSize))
            }

            pos += actualSize
        }

        return nil
    }

    /// Walk the atom tree properly: moov > trak > mdia > hdlr/minf > stbl > stts
    private static func findVideoStts(fileHandle: FileHandle, moovOffset: Int, moovSize: Int) -> Int? {
        let moovBodyOffset = moovOffset + 8
        let moovBodySize = moovSize - 8

        fileHandle.seek(toFileOffset: UInt64(moovBodyOffset))
        let moovData = fileHandle.readData(ofLength: moovBodySize)

        var pos = 0
        while pos + 8 <= moovData.count {
            let size = Int(readUInt32BE(moovData, offset: pos))
            guard size >= 8, pos + size <= moovData.count else { break }

            let atomType = readAtomType(moovData, offset: pos + 4)

            if atomType == "trak" {
                if let sttsFileOffset = findSttsInVideoTrak(moovData: moovData, trakOffset: pos, trakSize: size, moovBodyFileOffset: moovBodyOffset) {
                    return sttsFileOffset
                }
            }

            pos += size
        }

        return nil
    }

    private static func findSttsInVideoTrak(moovData: Data, trakOffset: Int, trakSize: Int, moovBodyFileOffset: Int) -> Int? {
        let trakBodyStart = trakOffset + 8
        let trakBodyEnd = trakOffset + trakSize

        var pos = trakBodyStart
        while pos + 8 <= trakBodyEnd {
            let size = Int(readUInt32BE(moovData, offset: pos))
            guard size >= 8, pos + size <= trakBodyEnd else { break }

            let atomType = readAtomType(moovData, offset: pos + 4)

            if atomType == "mdia" {
                if let sttsOffset = findSttsInMdia(moovData: moovData, mdiaOffset: pos, mdiaSize: size, moovBodyFileOffset: moovBodyFileOffset) {
                    return sttsOffset
                }
            }

            pos += size
        }

        return nil
    }

    private static func findSttsInMdia(moovData: Data, mdiaOffset: Int, mdiaSize: Int, moovBodyFileOffset: Int) -> Int? {
        let mdiaBodyStart = mdiaOffset + 8
        let mdiaBodyEnd = mdiaOffset + mdiaSize

        var isVideoTrack = false
        var minfOffset = -1
        var minfSize = 0

        var pos = mdiaBodyStart
        while pos + 8 <= mdiaBodyEnd {
            let size = Int(readUInt32BE(moovData, offset: pos))
            guard size >= 8, pos + size <= mdiaBodyEnd else { break }

            let atomType = readAtomType(moovData, offset: pos + 4)

            if atomType == "hdlr" {
                let handlerTypeOffset = pos + 8 + 4 + 4
                if handlerTypeOffset + 4 <= pos + size {
                    let handlerType = readAtomType(moovData, offset: handlerTypeOffset)
                    isVideoTrack = (handlerType == "vide")
                }
            } else if atomType == "minf" {
                minfOffset = pos
                minfSize = size
            }

            pos += size
        }

        guard isVideoTrack, minfOffset >= 0 else { return nil }

        return findSttsInMinf(moovData: moovData, minfOffset: minfOffset, minfSize: minfSize, moovBodyFileOffset: moovBodyFileOffset)
    }

    private static func findSttsInMinf(moovData: Data, minfOffset: Int, minfSize: Int, moovBodyFileOffset: Int) -> Int? {
        let minfBodyStart = minfOffset + 8
        let minfBodyEnd = minfOffset + minfSize

        var pos = minfBodyStart
        while pos + 8 <= minfBodyEnd {
            let size = Int(readUInt32BE(moovData, offset: pos))
            guard size >= 8, pos + size <= minfBodyEnd else { break }

            let atomType = readAtomType(moovData, offset: pos + 4)

            if atomType == "stbl" {
                let stblBodyStart = pos + 8
                let stblBodyEnd = pos + size

                var innerPos = stblBodyStart
                while innerPos + 8 <= stblBodyEnd {
                    let innerSize = Int(readUInt32BE(moovData, offset: innerPos))
                    guard innerSize >= 8, innerPos + innerSize <= stblBodyEnd else { break }

                    let innerType = readAtomType(moovData, offset: innerPos + 4)

                    if innerType == "stts" {
                        return moovBodyFileOffset + innerPos
                    }

                    innerPos += innerSize
                }
            }

            pos += size
        }

        return nil
    }

    private static func analyzeStts(fileHandle: FileHandle, sttsOffset: Int) -> SttsInfo? {
        fileHandle.seek(toFileOffset: UInt64(sttsOffset))
        let headerData = fileHandle.readData(ofLength: 8)
        guard headerData.count == 8 else { return nil }

        let size = Int(readUInt32BE(headerData, offset: 0))
        let atomType = readAtomType(headerData, offset: 4)
        guard atomType == "stts" else { return nil }

        let vfData = fileHandle.readData(ofLength: 4)
        guard vfData.count == 4 else { return nil }

        let ecData = fileHandle.readData(ofLength: 4)
        guard ecData.count == 4 else { return nil }
        let entryCount = Int(readUInt32BE(ecData, offset: 0))

        guard entryCount > 0, entryCount < 100000 else { return nil }

        var entries: [SttsEntry] = []
        for _ in 0..<entryCount {
            let entryData = fileHandle.readData(ofLength: 8)
            guard entryData.count == 8 else { break }
            let count = Int(readUInt32BE(entryData, offset: 0))
            let delta = Int(readUInt32BE(entryData, offset: 4))
            entries.append(SttsEntry(count: count, delta: delta))
        }

        let totalSamples = entries.reduce(0) { $0 + $1.count }

        var deltaCounts: [Int: Int] = [:]
        for entry in entries {
            deltaCounts[entry.delta, default: 0] += entry.count
        }
        let dominantDelta = deltaCounts.max(by: { $0.value < $1.value })?.key ?? entries.first?.delta ?? 0

        return SttsInfo(
            offset: sttsOffset,
            size: size,
            entryCount: entryCount,
            entries: entries,
            totalSamples: totalSamples,
            dominantDelta: dominantDelta
        )
    }

    // MARK: - Binary helpers

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) << 24 |
               UInt32(data[start+1]) << 16 |
               UInt32(data[start+2]) << 8 |
               UInt32(data[start+3])
    }

    private static func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
        let start = data.startIndex + offset
        return UInt64(data[start]) << 56 |
               UInt64(data[start+1]) << 48 |
               UInt64(data[start+2]) << 40 |
               UInt64(data[start+3]) << 32 |
               UInt64(data[start+4]) << 24 |
               UInt64(data[start+5]) << 16 |
               UInt64(data[start+6]) << 8 |
               UInt64(data[start+7])
    }

    private static func readAtomType(_ data: Data, offset: Int) -> String {
        let start = data.startIndex + offset
        guard start + 4 <= data.endIndex else { return "" }
        return String(data: data[start..<start+4], encoding: .ascii) ?? ""
    }
}
