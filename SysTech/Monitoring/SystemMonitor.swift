//
//  SystemMonitor.swift
//  SysTech
//

import Foundation
import Observation

/// Polls `SystemSampler` on the configured interval and publishes the latest
/// snapshot plus a short history for the sparklines.
@Observable
final class SystemMonitor {
    static let historyLength = 60

    private(set) var snapshot = SystemSnapshot.empty
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []

    let machine = MachineInfo.current

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        start()
    }

    /// Metrics this Mac can actually report (e.g. no fan row on a MacBook Air).
    var availableMetrics: [Metric] {
        Metric.allCases.filter(isAvailable)
    }

    func isAvailable(_ metric: Metric) -> Bool {
        switch metric {
        case .cpu, .memory, .network, .disk: true
        case .cpuTemperature: snapshot.cpuTemperature != nil
        case .gpu: snapshot.gpuUsage != nil
        case .gpuTemperature: snapshot.gpuTemperature != nil
        case .battery: snapshot.battery != nil
        case .fan: !snapshot.fans.isEmpty
        }
    }

    private func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await sampler.sample()
                apply(snapshot)
                try? await Task.sleep(for: .seconds(settings.refreshInterval))
            }
        }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        if let cpu = snapshot.cpu { append(cpu.usage, to: &cpuHistory) }
        if let memory = snapshot.memory { append(memory.usage, to: &memoryHistory) }
        if let gpu = snapshot.gpuUsage { append(gpu, to: &gpuHistory) }
        if let network = snapshot.network {
            append(network.downloadRate, to: &downloadHistory)
            append(network.uploadRate, to: &uploadHistory)
        }
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }
}

/// Static facts about the Mac, read once.
struct MachineInfo {
    var chip: String
    var performanceCores: Int
    var efficiencyCores: Int
    var physicalMemory: UInt64
    var osVersion: String

    static let current = MachineInfo(
        chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
        performanceCores: sysctlInt("hw.perflevel0.logicalcpu") ?? ProcessInfo.processInfo.processorCount,
        efficiencyCores: sysctlInt("hw.perflevel1.logicalcpu") ?? 0,
        physicalMemory: ProcessInfo.processInfo.physicalMemory,
        osVersion: {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
            return "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
        }()
    )

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}
