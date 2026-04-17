// GyLogSyncApp.swift
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/GyLogSync

import SwiftUI

@main
struct GyLogSyncApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 650)
                .navigationTitle("GyLog Sync Direct")
        }
        .windowStyle(.hiddenTitleBar)
    }
}
