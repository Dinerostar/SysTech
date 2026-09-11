//
//  MonitorPanel.swift
//  SysTech
//

import AppKit
import SwiftUI

/// The window that drops down from the menu bar item.
struct MonitorPanel: View {
    let monitor: SystemMonitor
    @Bindable var settings: AppSettings

    @State private var isShowingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isShowingSettings {
                SettingsPanel(settings: settings)
            } else {
                VStack(spacing: 6) {
                    ForEach(monitor.availableMetrics) { metric in
                        MetricCard(metric: metric, monitor: monitor, settings: settings)
                    }
                }
                .padding(10)
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SysTech")
                    .font(.headline)
                Text(machineSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Label(Format.uptime(ProcessInfo.processInfo.systemUptime), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Time since last restart")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var machineSummary: String {
        let machine = monitor.machine
        return "\(machine.chip) · \(Format.memory(machine.physicalMemory)) · \(machine.osVersion)"
    }

    private var footer: some View {
        HStack {
            // No animation: an animated size change can leave the menu bar
            // window shorter than its content, clipping this footer.
            Button {
                isShowingSettings.toggle()
            } label: {
                Label(isShowingSettings ? "Back" : "Settings",
                      systemImage: isShowingSettings ? "chevron.backward" : "gearshape")
            }

            Spacer()

            if !isShowingSettings {
                Text("Switch on to show in menu bar")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        // Extra inset keeps the buttons clear of the window's rounded corners.
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
}

// MARK: - Metric card

/// One metric: title, current value and menu bar switch on top, chart and
/// details below.
struct MetricCard: View {
    let metric: Metric
    let monitor: SystemMonitor
    let settings: AppSettings

    private var snapshot: SystemSnapshot { monitor.snapshot }
    private var unit: TemperatureUnit { settings.temperatureUnit }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(metric.tint)
                    .frame(width: 18)
                Text(metric.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Toggle("Show \(metric.title) in menu bar", isOn: settings.isInMenuBar(metric))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Show in menu bar")
                    .padding(.leading, 4)
            }

            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var symbol: String {
        if metric == .battery, let battery = snapshot.battery {
            return MenuBarLabel.batterySymbol(battery)
        }
        return metric.symbol
    }

    /// Headline value shown next to the title.
    private var value: String? {
        switch metric {
        case .cpu: snapshot.cpu.map { Format.percent($0.usage) } ?? "…"
        case .cpuTemperature: snapshot.cpuTemperature.map { Format.temperature($0.average, unit: unit) }
        case .memory: snapshot.memory.map { "\(Format.memory($0.used)) / \(Format.memory($0.total))" }
        case .gpu: snapshot.gpuUsage.map { Format.percent($0) }
        case .gpuTemperature: snapshot.gpuTemperature.map { Format.temperature($0.average, unit: unit) }
        case .network: nil
        case .disk: snapshot.disk.map { "\(Format.storage($0.available)) free" }
        case .battery: snapshot.battery.map { Format.percent($0.level) }
        case .fan: snapshot.fans.max(by: { $0.rpm < $1.rpm }).map { "\(Int($0.rpm)) rpm" }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch metric {
        case .cpu:
            // Usage needs two samples; keep the full layout meanwhile so the card doesn't grow later.
            let cpu = snapshot.cpu
            Sparkline(values: monitor.cpuHistory, maximum: 1, color: metric.tint)
                .frame(height: 24)
            CoreBars(usages: cpu?.perCore ?? Array(repeating: 0, count: monitor.machine.totalCores), color: metric.tint)
                .frame(height: 10)
            caption("User \(cpu.map { Format.percent($0.user) } ?? "–") · System \(cpu.map { Format.percent($0.system) } ?? "–") · \(coreSummary)")

        case .cpuTemperature:
            if let temperature = snapshot.cpuTemperature {
                temperatureContent(temperature)
            }

        case .memory:
            if let memory = snapshot.memory {
                UsageBar(fraction: memory.usage, color: pressureColor(memory.pressure))
                caption("Pressure \(pressureTitle(memory.pressure)) · App \(Format.memory(memory.app)) · Wired \(Format.memory(memory.wired))")
                caption("Compressed \(Format.memory(memory.compressed)) · Cached \(Format.memory(memory.cached)) · Swap \(Format.memory(memory.swapUsed))")
            }

        case .gpu:
            Sparkline(values: monitor.gpuHistory, maximum: 1, color: metric.tint)
                .frame(height: 20)

        case .gpuTemperature:
            if let temperature = snapshot.gpuTemperature {
                temperatureContent(temperature)
            }

        case .network:
            if let network = snapshot.network {
                let peak = max(monitor.downloadHistory.max() ?? 0, monitor.uploadHistory.max() ?? 0, 1024)
                ZStack {
                    Sparkline(values: monitor.downloadHistory, maximum: peak, color: metric.tint)
                    Sparkline(values: monitor.uploadHistory, maximum: peak, color: .orange, filled: false)
                }
                .frame(height: 24)
                HStack {
                    Label(Format.rate(network.downloadRate), systemImage: "arrow.down")
                        .foregroundStyle(metric.tint)
                    Label(Format.rate(network.uploadRate), systemImage: "arrow.up")
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("Since boot ↓ \(Format.storage(network.totalDownloaded)) ↑ \(Format.storage(network.totalUploaded))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }

        case .disk:
            if let disk = snapshot.disk {
                UsageBar(fraction: disk.usage, color: disk.usage > 0.9 ? .red : metric.tint)
                caption("\(Format.storage(disk.used)) used of \(Format.storage(disk.total))")
            }

        case .battery:
            if let battery = snapshot.battery {
                UsageBar(fraction: battery.level, color: battery.level < 0.2 ? .red : metric.tint)
                caption(batteryDetails(battery))
            }

        case .fan:
            ForEach(Array(snapshot.fans.enumerated()), id: \.offset) { index, fan in
                if let maxRPM = fan.maxRPM, maxRPM > 0 {
                    UsageBar(fraction: fan.rpm / maxRPM, color: metric.tint)
                }
                if snapshot.fans.count > 1 {
                    caption("Fan \(index + 1): \(Int(fan.rpm)) rpm")
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    @ViewBuilder
    private func temperatureContent(_ temperature: SystemSnapshot.Temperature) -> some View {
        UsageBar(fraction: temperature.average / 105, color: temperatureColor(temperature.average))
        caption("Hottest sensor \(Format.temperature(temperature.hottest, unit: unit))")
    }

    private var coreSummary: String {
        let machine = monitor.machine
        guard machine.efficiencyCores > 0 else { return "\(machine.performanceCores) cores" }
        return "\(machine.performanceCores)P + \(machine.efficiencyCores)E cores"
    }

    private func temperatureColor(_ celsius: Double) -> Color {
        switch celsius {
        case ..<60: .green
        case ..<80: .orange
        default: .red
        }
    }

    private func pressureTitle(_ pressure: SystemSnapshot.MemoryPressure) -> String {
        switch pressure {
        case .normal: "normal"
        case .warning: "elevated"
        case .critical: "critical"
        }
    }

    private func pressureColor(_ pressure: SystemSnapshot.MemoryPressure) -> Color {
        switch pressure {
        case .normal: metric.tint
        case .warning: .orange
        case .critical: .red
        }
    }

    private func batteryDetails(_ battery: SystemSnapshot.Battery) -> String {
        var parts = [battery.isCharging ? "Charging" : (battery.isOnACPower ? "On power adapter" : "On battery")]
        if let minutes = battery.minutesRemaining {
            parts.append("\(Format.duration(minutes: minutes)) \(battery.isCharging ? "to full" : "left")")
        }
        if let cycles = battery.cycleCount { parts.append("\(cycles) cycles") }
        if let temperature = battery.temperature { parts.append(Format.temperature(temperature, unit: unit)) }
        return parts.joined(separator: " · ")
    }
}


// MARK: - Charts

struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: fraction)
    }
}

struct Sparkline: View {
    let values: [Double]
    let maximum: Double
    let color: Color
    var filled = true

    var body: some View {
        GeometryReader { proxy in
            let points = points(in: proxy.size)
            if points.count > 1 {
                ZStack {
                    if filled {
                        Path { path in
                            path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                            points.forEach { path.addLine(to: $0) }
                            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: proxy.size.height))
                            path.closeSubpath()
                        }
                        .fill(color.opacity(0.18).gradient)
                    }
                    Path { path in
                        path.addLines(points)
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    /// Newest value on the right; the line grows in from the right until history fills.
    private func points(in size: CGSize) -> [CGPoint] {
        guard maximum > 0 else { return [] }
        let step = size.width / CGFloat(SystemMonitor.historyLength - 1)
        let start = size.width - step * CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let normalized = min(max(value / maximum, 0), 1)
            return CGPoint(x: start + step * CGFloat(index), y: size.height * (1 - normalized))
        }
    }
}

struct CoreBars: View {
    let usages: [Double]
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(usages.enumerated()), id: \.offset) { _, usage in
                GeometryReader { proxy in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color.gradient)
                            .frame(height: max(proxy.size.height * usage, 1))
                    }
                }
            }
        }
        .animation(.smooth, value: usages)
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Refresh every", selection: $settings.refreshInterval) {
                ForEach(AppSettings.refreshIntervals, id: \.self) { interval in
                    Text("\(Int(interval)) s").tag(interval)
                }
            }

            Picker("Menu bar style", selection: $settings.menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            Picker("Temperature", selection: $settings.temperatureUnit) {
                ForEach(TemperatureUnit.allCases) { unit in
                    Text(unit.symbol).tag(unit)
                }
            }

            Toggle("Launch at login", isOn: $settings.launchAtLogin)
        }
        .pickerStyle(.segmented)
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 230)
    }
}
