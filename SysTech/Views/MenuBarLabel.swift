//
//  MenuBarLabel.swift
//  SysTech
//

import AppKit
import SwiftUI

/// One slot in the menu bar strip.
struct MenuBarItem: Identifiable {
    let metric: Metric
    var symbol: String?
    var lines: [String]
    /// Widest expected value, reserved up front so the strip doesn't jitter.
    var placeholder: String

    var id: Metric { metric }
}

/// The menu bar label. `MenuBarExtra` only renders a single image/text, so the
/// strip is drawn with `ImageRenderer` into a template image.
struct MenuBarLabel: View {
    let monitor: SystemMonitor
    let settings: AppSettings

    var body: some View {
        let items = makeItems()
        if items.isEmpty {
            Image(systemName: "gauge.with.dots.needle.50percent")
        } else if let image = render(items) {
            Image(nsImage: image)
                .accessibilityLabel(items.map { "\($0.metric.title) \($0.lines.joined(separator: " "))" }.joined(separator: ", "))
        }
    }

    private func render(_ items: [MenuBarItem]) -> NSImage? {
        let renderer = ImageRenderer(content: MenuBarStrip(items: items, style: settings.menuBarStyle))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }

    private func makeItems() -> [MenuBarItem] {
        let snapshot = monitor.snapshot
        let unit = settings.temperatureUnit

        return Metric.allCases
            .filter { settings.menuBarMetrics.contains($0) && monitor.isAvailable($0) }
            .compactMap { metric in
                switch metric {
                case .cpu:
                    guard let cpu = snapshot.cpu else { return nil }
                    return MenuBarItem(metric: metric, symbol: metric.symbol, lines: [Format.percent(cpu.usage)], placeholder: "100%")
                case .cpuTemperature:
                    guard let temperature = snapshot.cpuTemperature else { return nil }
                    return MenuBarItem(metric: metric, symbol: metric.symbol,
                                       lines: [Format.compactTemperature(temperature.average, unit: unit)], placeholder: "100°")
                case .memory:
                    guard let memory = snapshot.memory else { return nil }
                    return MenuBarItem(metric: metric, symbol: metric.symbol, lines: [Format.percent(memory.usage)], placeholder: "100%")
                case .gpu:
                    guard let gpu = snapshot.gpuUsage else { return nil }
                    return MenuBarItem(metric: metric, symbol: metric.symbol, lines: [Format.percent(gpu)], placeholder: "100%")
                case .gpuTemperature:
                    guard let temperature = snapshot.gpuTemperature else { return nil }
                    return MenuBarItem(metric: metric, symbol: metric.symbol,
                                       lines: [Format.compactTemperature(temperature.average, unit: unit)], placeholder: "100°")
                case .network:
                    guard let network = snapshot.network else { return nil }
                    return MenuBarItem(metric: metric, symbol: nil,
                                       lines: ["↑ " + Format.compactRate(network.uploadRate),
                                               "↓ " + Format.compactRate(network.downloadRate)],
                                       placeholder: "↑ 999K")
                case .disk:
                    guard let disk = snapshot.disk else { return nil }
                    return MenuBarItem(metric: metric, symbol: metric.symbol, lines: [Format.percent(disk.usage)], placeholder: "100%")
                case .battery:
                    guard let battery = snapshot.battery else { return nil }
                    return MenuBarItem(metric: metric, symbol: Self.batterySymbol(battery),
                                       lines: [Format.percent(battery.level)], placeholder: "100%")
                case .fan:
                    guard let fan = snapshot.fans.max(by: { $0.rpm < $1.rpm }) else { return nil }
                    return MenuBarItem(metric: metric, symbol: metric.symbol, lines: ["\(Int(fan.rpm))"], placeholder: "8888")
                }
            }
    }

    static func batterySymbol(_ battery: SystemSnapshot.Battery) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// The view that gets rasterized for the menu bar. Drawn in black; the
/// template image lets macOS tint it for light/dark menu bars.
struct MenuBarStrip: View {
    let items: [MenuBarItem]
    let style: MenuBarStyle

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                cell(for: item)
            }
        }
        .frame(height: 22)
        .foregroundStyle(.black)
    }

    @ViewBuilder
    private func cell(for item: MenuBarItem) -> some View {
        let isStacked = item.lines.count > 1
        switch style {
        case .icons:
            HStack(spacing: 3) {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                values(for: item, size: isStacked ? 9 : 12)
            }
        case .labels:
            if isStacked {
                values(for: item, size: 9)
            } else {
                VStack(alignment: .leading, spacing: -1) {
                    Text(item.metric.shortLabel)
                        .font(.system(size: 7.5, weight: .bold))
                    values(for: item, size: 11)
                }
            }
        }
    }

    private func values(for item: MenuBarItem, size: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: -2) {
            ForEach(Array(item.lines.enumerated()), id: \.offset) { _, line in
                ZStack(alignment: .trailing) {
                    Text(item.placeholder).hidden()
                    Text(line)
                }
            }
        }
        .font(.system(size: size, weight: .medium).monospacedDigit())
    }
}
