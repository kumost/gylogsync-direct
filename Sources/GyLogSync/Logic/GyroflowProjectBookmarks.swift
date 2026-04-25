// GyroflowProjectBookmarks.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

import Foundation
import Compression

/// Embeds macOS file bookmarks for the source video and gcsv into a .gyroflow
/// project JSON so Gyroflow Desktop can open the project for fine-tuning
/// (rolling-shutter slider, sync slider, smoothness, etc). Without these
/// bookmarks Gyroflow Desktop cannot resolve files referenced by plain paths
/// inside its sandbox/TCC boundary, and the project fails to load even when
/// the user has access in Finder.
///
/// On-disk format used by Gyroflow's .gyroflow files:
///   videofile_bookmark = basE91( zlib( Apple bookmark binary ) )
///   gyro_source.filepath_bookmark = same encoding for the gcsv
/// Both bookmarks are non-security-scoped (Gyroflow Desktop is non-sandboxed).
///
/// gyroflow-core (used by DaVinci OFX) does NOT need either field — it reads
/// videofile / gyro_source.filepath as plain paths. So failures here are
/// non-fatal: the .gyroflow remains valid for OFX even if embedding fails.
enum GyroflowProjectBookmarks {

    static func embed(video: URL, gcsv: URL, gyroflowPath: String) {
        do {
            let videoBookmark = try video.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let gcsvBookmark = try gcsv.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            guard let videoZlib = zlibWrap(videoBookmark),
                  let gcsvZlib = zlibWrap(gcsvBookmark) else {
                print("WARNING: zlib wrap failed; skipping bookmark embed for \(gyroflowPath)")
                return
            }

            let videoEncoded = base91Encode(videoZlib)
            let gcsvEncoded = base91Encode(gcsvZlib)

            let gyroflowURL = URL(fileURLWithPath: gyroflowPath)
            let data = try Data(contentsOf: gyroflowURL)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("WARNING: .gyroflow root is not a JSON object; skipping bookmark embed for \(gyroflowURL.lastPathComponent)")
                return
            }

            json["videofile"] = video.absoluteString
            json["videofile_bookmark"] = videoEncoded

            var gyroSource = (json["gyro_source"] as? [String: Any]) ?? [:]
            gyroSource["filepath"] = gcsv.absoluteString
            gyroSource["filepath_bookmark"] = gcsvEncoded
            json["gyro_source"] = gyroSource

            let updated = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            // Atomic write: macOS will write to a temp file and rename,
            // so a crash mid-write leaves the original .gyroflow intact
            // instead of producing a half-written file that breaks both
            // Gyroflow Desktop and DaVinci OFX on next open.
            try updated.write(to: gyroflowURL, options: .atomic)
        } catch {
            print("WARNING: Failed to embed file bookmarks in \(gyroflowPath): \(error)")
        }
    }

    // MARK: - zlib wrapping
    // Apple's Compression framework with COMPRESSION_ZLIB produces *raw* DEFLATE
    // (RFC 1951), not zlib format (RFC 1950). Gyroflow expects RFC 1950, so we
    // wrap manually: 2-byte zlib header + raw DEFLATE + 4-byte big-endian Adler-32.

    private static func zlibWrap(_ src: Data) -> Data? {
        let dstCapacity = src.count + 64
        var deflated = Data(count: dstCapacity)
        let n: Int = deflated.withUnsafeMutableBytes { dstBuf in
            guard let dstPtr = dstBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return src.withUnsafeBytes { srcBuf -> Int in
                guard let srcPtr = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_encode_buffer(
                    dstPtr, dstCapacity,
                    srcPtr, src.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard n > 0 else { return nil }
        deflated.count = n

        var out = Data(capacity: n + 6)
        out.append(contentsOf: [0x78, 0xDA])
        out.append(deflated)
        let adler = adler32(src)
        out.append(UInt8((adler >> 24) & 0xFF))
        out.append(UInt8((adler >> 16) & 0xFF))
        out.append(UInt8((adler >> 8) & 0xFF))
        out.append(UInt8(adler & 0xFF))
        return out
    }

    private static func adler32(_ data: Data) -> UInt32 {
        let mod: UInt32 = 65521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % mod
            b = (b + a) % mod
        }
        return (b << 16) | a
    }

    // MARK: - basE91 encoding (Henke alphabet)

    private static let base91Alphabet: [Character] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&()*+,./:;<=>?@[]^_`{|}~\""
    )

    private static func base91Encode(_ data: Data) -> String {
        var b: UInt32 = 0
        var n: Int = 0
        var out = ""
        for byte in data {
            b |= UInt32(byte) << n
            n += 8
            if n > 13 {
                var v = b & 8191
                if v > 88 {
                    b >>= 13
                    n -= 13
                } else {
                    v = b & 16383
                    b >>= 14
                    n -= 14
                }
                out.append(base91Alphabet[Int(v % 91)])
                out.append(base91Alphabet[Int(v / 91)])
            }
        }
        if n > 0 {
            out.append(base91Alphabet[Int(b % 91)])
            if n > 7 || b > 90 {
                out.append(base91Alphabet[Int(b / 91)])
            }
        }
        return out
    }
}
