// FileUtils.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

import Foundation

enum FileUtils {
    /// If a file already exists at `url`, rename it to `<url>.prev` before the caller
    /// writes the new version. One generation of rollback is preserved per output
    /// location. If `<url>.prev` already exists from an earlier run, it is overwritten.
    /// Use this before every output write to avoid silent data loss on re-processing.
    static func preserveIfExists(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("prev")
        if fm.fileExists(atPath: backup.path) {
            try fm.removeItem(at: backup)
        }
        try fm.moveItem(at: url, to: backup)
    }
}
