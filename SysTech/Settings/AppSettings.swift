//
//  AppSettings.swift
//  SysTech
//

import Foundation
import Observation
import ServiceManagement
import SwiftUI

enum Metric: String, CaseIterable, Identifiable {
    case cpu
    case cpuTemperature
    case memory
    case gpu
    case gpuTemperature
    case network
    case disk
    case battery
    case fan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .cpuTemperature: "CPU Temperature"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .gpuTemperature: "GPU Temperature"
        case .network: "Network"
        case .disk: "Disk"
        case .battery: "Battery"
        case .fan: "Fans"
        }
    }

    /// Caption used by the stacked "Labels" menu bar style.
    var shortLabel: String {
        switch self {
        case .cpu: "CPU"
        case .cpuTemperature: "CPU°"
        case .memory: "RAM"
        case .gpu: "GPU"
        case .gpuTemperature: "GPU°"
        case .network: "NET"
        case .disk: "SSD"
        case .battery: "BAT"
        case .fan: "FAN"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .cpuTemperature: "thermometer.medium"
        case .memory: "memorychip"
        case .gpu: "square.stack.3d.up"
        case .gpuTemperature: "thermometer.variable"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        case .battery: "battery.100percent"
        case .fan: "fan"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: .blue
        case .cpuTemperature: .orange
        case .memory: .purple
        case .gpu: .teal
        case .gpuTemperature: .pink
        case .network: .indigo
        case .disk: .gray
        case .battery: .green
        case .fan: .cyan
        }
    }

    static let defaultMenuBarMetrics: Set<Metric> = [.cpu, .cpuTemperature, .memory]
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icons
    case labels

    var id: String { rawValue }
    var title: String { self == .icons ? "Icons" : "Labels" }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }

    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }
}

/// User preferences, persisted in `UserDefaults`.
@Observable
final class AppSettings {
    private enum Keys {
        static let menuBarMetrics = "menuBarMetrics"
        static let refreshInterval = "refreshInterval"
        static let menuBarStyle = "menuBarStyle"
        static let temperatureUnit = "temperatureUnit"
    }

    static let refreshIntervals: [Double] = [1, 2, 5]

    @ObservationIgnored private let defaults: UserDefaults

    var menuBarMetrics: Set<Metric> {
        didSet { defaults.set(menuBarMetrics.map(\.rawValue), forKey: Keys.menuBarMetrics) }
    }

    var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) }
    }

    var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Keys.temperatureUnit) }
    }

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("SysTech: failed to update login item: \(error)")
                }
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let stored = defaults.stringArray(forKey: Keys.menuBarMetrics) {
            menuBarMetrics = Set(stored.compactMap(Metric.init(rawValue:)))
        } else {
            menuBarMetrics = Metric.defaultMenuBarMetrics
        }

        let interval = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = Self.refreshIntervals.contains(interval) ? interval : 2
        menuBarStyle = defaults.string(forKey: Keys.menuBarStyle).flatMap(MenuBarStyle.init(rawValue:)) ?? .icons
        temperatureUnit = defaults.string(forKey: Keys.temperatureUnit).flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
    }

    func isInMenuBar(_ metric: Metric) -> Binding<Bool> {
        Binding(
            get: { self.menuBarMetrics.contains(metric) },
            set: { isOn in
                if isOn {
                    self.menuBarMetrics.insert(metric)
                } else {
                    self.menuBarMetrics.remove(metric)
                }
            }
        )
    }
}
