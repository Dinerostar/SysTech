//
//  SystemSnapshot.swift
//  SysTech
//

import Foundation

/// One reading of every metric. Optional values are `nil` when the Mac
/// doesn't have that hardware (no fans, no battery, …) or a read failed.
nonisolated struct SystemSnapshot: Sendable {
    struct CPU: Sendable {
        var usage: Double          // 0...1
        var user: Double
        var system: Double
        var perCore: [Double]
    }

    struct Memory: Sendable {
        var total: UInt64
        var used: UInt64
        var app: UInt64
        var wired: UInt64
        var compressed: UInt64
        var cached: UInt64
        var swapUsed: UInt64
        var pressure: MemoryPressure

        var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    enum MemoryPressure: Sendable {
        case normal, warning, critical
    }

    struct Temperature: Sendable {
        var average: Double        // °C
        var hottest: Double
    }

    struct Network: Sendable {
        var downloadRate: Double   // bytes per second
        var uploadRate: Double
        var totalDownloaded: UInt64
        var totalUploaded: UInt64
    }

    struct Disk: Sendable {
        var total: UInt64
        var available: UInt64

        var used: UInt64 { total > available ? total - available : 0 }
        var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    struct Battery: Sendable {
        var level: Double          // 0...1
        var isCharging: Bool
        var isOnACPower: Bool
        var minutesRemaining: Int? // to empty, or to full while charging
        var cycleCount: Int?
        var temperature: Double?
    }

    struct Fan: Sendable {
        var rpm: Double
        var maxRPM: Double?
    }

    var cpu: CPU?
    var cpuTemperature: Temperature?
    var memory: Memory?
    var gpuUsage: Double?
    var gpuTemperature: Temperature?
    var network: Network?
    var disk: Disk?
    var battery: Battery?
    var fans: [Fan] = []

    static let empty = SystemSnapshot()
}
