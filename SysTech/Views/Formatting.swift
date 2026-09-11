//
//  Formatting.swift
//  SysTech
//

import Foundation

enum Format {
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "47°" for the menu bar.
    static func compactTemperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        "\(Int(unit.convert(celsius).rounded()))°"
    }

    /// "47 °C" for the panel.
    static func temperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        "\(Int(unit.convert(celsius).rounded())) \(unit.symbol)"
    }

    /// RAM sizes, binary units like Activity Monitor: "17.4 GB".
    static func memory(_ bytes: UInt64) -> String {
        let (value, prefix) = scaled(Double(bytes), base: 1024, decimalsBelow: 100)
        return "\(value) \(prefix)B"
    }

    /// Disk and transfer sizes, decimal units like Finder: "181 GB".
    static func storage(_ bytes: UInt64) -> String {
        let (value, prefix) = scaled(Double(bytes), base: 1000, decimalsBelow: 100)
        return "\(value) \(prefix)B"
    }

    /// "1.2 MB/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        let (value, prefix) = scaled(bytesPerSecond, base: 1000, decimalsBelow: 10)
        return "\(value) \(prefix)B/s"
    }

    /// "1.2M" — fits the narrow menu bar slot.
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let (value, prefix) = scaled(bytesPerSecond, base: 1000, decimalsBelow: 10)
        return "\(value)\(prefix.isEmpty ? "B" : prefix)"
    }

    /// Scales to K/M/G/T; shows one decimal while the value is below `decimalsBelow`.
    private static func scaled(_ amount: Double, base: Double, decimalsBelow: Double) -> (String, String) {
        let prefixes = ["", "K", "M", "G", "T"]
        var value = max(amount, 0)
        var index = 0
        while value >= base, index < prefixes.count - 1 {
            value /= base
            index += 1
        }
        let decimals = value < decimalsBelow && index > 0 ? 1 : 0
        return (value.formatted(.number.precision(.fractionLength(0...decimals))), prefixes[index])
    }

    static func duration(minutes: Int) -> String {
        "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        return "\(hours)h \(minutes % 60)m"
    }
}
