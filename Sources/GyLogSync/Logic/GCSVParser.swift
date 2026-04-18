// GCSVParser.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

import Foundation

struct GCSVSample {
    let rawLine: String
    let timestamp: Double // Seconds since 1970
}

class GCSVParser {
    static func parse(url: URL) throws -> [GCSVSample] {
        let content = try String(contentsOf: url)
        let lines = content.components(separatedBy: .newlines)
        
        var samples: [GCSVSample] = []
        var tscale: Double = 1e-9 // Default nano
        
        for line in lines {
            if line.isEmpty { continue }
            if line.hasPrefix("tscale") {
                 let parts = line.split(separator: ",")
                 if parts.count > 1, let scale = Double(parts[1]) {
                     tscale = scale
                 }
                 continue
            }
            // Skip non-data lines (Header)
            // Data lines start with number or minus sign
            if let firstChar = line.first, !firstChar.isNumber && firstChar != "-" {
                continue
            }
            
            // Data line
            let parts = line.split(separator: ",") // Fast split
            if let tVal = Double(parts[0]) {
                // Determine if timestamp is absolute or relative?
                // GyLog uses absolute logical timestamp (Since1970 * 1e9) in MotionRecorder.swift
                // So tVal * tscale = Seconds Since 1970
                let seconds = tVal * tscale
                samples.append(GCSVSample(rawLine: line, timestamp: seconds))
            }
        }
        return samples
    }
    
    static func getHeader(url: URL) throws -> String {
        let content = try String(contentsOf: url)
        var headerLines: [String] = []
        content.enumerateLines { line, stop in
             if !line.isEmpty, let firstChar = line.first, (firstChar.isNumber || firstChar == "-") {
                 stop = true
             } else {
                 headerLines.append(line)
             }
        }
        return headerLines.joined(separator: "\n")
    }

    static func export(samples: [GCSVSample], to url: URL, header: String) throws {
        var content = header
        if !content.hasSuffix("\n") { content += "\n" }

        content += samples.map { $0.rawLine }.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // Extract install_angle:R{roll}_P{pitch} from a gcsv header/note string.
    // Returns nil if not present.
    static func parseInstallAngle(fromHeader text: String) -> (roll: Double, pitch: Double)? {
        let pattern = #"install_angle:R(-?\d+)_P(-?\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 3,
              let rRange = Range(match.range(at: 1), in: text),
              let pRange = Range(match.range(at: 2), in: text),
              let roll = Double(text[rRange]),
              let pitch = Double(text[pRange])
        else { return nil }
        return (roll, pitch)
    }
}
