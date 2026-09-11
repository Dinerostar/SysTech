//
//  SysTechApp.swift
//  SysTech
//
//  Created by Marko on 11. 9. 2026.
//

import SwiftUI

@main
struct SysTechApp: App {
    @State private var settings: AppSettings
    @State private var monitor: SystemMonitor

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _monitor = State(initialValue: SystemMonitor(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPanel(monitor: monitor, settings: settings)
        } label: {
            MenuBarLabel(monitor: monitor, settings: settings)
        }
        .menuBarExtraStyle(.window)
    }
}
