//
//  SystemSampler.swift
//  SysTech
//

import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Reads raw system counters off the main thread and turns them into a
/// `SystemSnapshot`. Rates (CPU, network) are computed against the previous call.
actor SystemSampler {
    private let host = mach_host_self()
    private var pageSize: UInt64 = 0

    private var previousCPUTicks: [CPUTicks] = []
    private var previousNetwork: (bytesIn: UInt64, bytesOut: UInt64, time: TimeInterval)?

    private var sensorsDiscovered = false
    private var cpuTemperatureKeys: [String] = []
    private var gpuTemperatureKeys: [String] = []
    private var fanCount = 0

    func sample() -> SystemSnapshot {
        if !sensorsDiscovered {
            discoverSensors()
        }

        var snapshot = SystemSnapshot()
        snapshot.cpu = readCPU()
        snapshot.memory = readMemory()
        snapshot.cpuTemperature = readCPUTemperature()
        snapshot.gpuUsage = readGPUUsage()
        snapshot.gpuTemperature = readTemperature(keys: gpuTemperatureKeys)
        snapshot.network = readNetwork()
        snapshot.disk = readDisk()
        snapshot.battery = readBattery()
        snapshot.fans = readFans()
        return snapshot
    }

    // MARK: - CPU

    private struct CPUTicks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private func readCPUTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        return (0..<Int(cpuCount)).map { core in
            let base = Int(CPU_STATE_MAX) * core
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    private func readCPU() -> SystemSnapshot.CPU? {
        let ticks = readCPUTicks()
        defer { previousCPUTicks = ticks }
        guard !ticks.isEmpty, ticks.count == previousCPUTicks.count else { return nil }

        var perCore: [Double] = []
        var totalUser = 0.0, totalSystem = 0.0, totalAll = 0.0

        for (now, before) in zip(ticks, previousCPUTicks) {
            // Counters are 32-bit and wrap, so subtract with overflow.
            let user = Double(now.user &- before.user) + Double(now.nice &- before.nice)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)
            let all = user + system + idle
            perCore.append(all > 0 ? (user + system) / all : 0)
            totalUser += user
            totalSystem += system
            totalAll += all
        }

        guard totalAll > 0 else { return nil }
        return SystemSnapshot.CPU(
            usage: (totalUser + totalSystem) / totalAll,
            user: totalUser / totalAll,
            system: totalSystem / totalAll,
            perCore: perCore
        )
    }

    // MARK: - Memory

    private func readMemory() -> SystemSnapshot.Memory? {
        if pageSize == 0 {
            var size: vm_size_t = 0
            host_page_size(host, &size)
            pageSize = UInt64(size)
        }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // Same breakdown Activity Monitor uses for "Memory Used".
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let cached = (UInt64(stats.external_page_count) + purgeable) * pageSize

        return SystemSnapshot.Memory(
            total: ProcessInfo.processInfo.physicalMemory,
            used: app + wired + compressed,
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            swapUsed: readSwapUsed(),
            pressure: readMemoryPressure()
        )
    }

    private func readSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private func readMemoryPressure() -> SystemSnapshot.MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    // MARK: - Temperatures & fans (SMC)

    private func discoverSensors() {
        sensorsDiscovered = true
        guard smc_open() else { return }

        var cpuKeys: [String] = []
        var gpuKeys: [String] = []
        let count = smc_key_count()

        for index in 0..<count {
            var buffer = [CChar](repeating: 0, count: 5)
            guard smc_key_at_index(index, &buffer) else { continue }
            let key = String(decoding: buffer.prefix(4).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard key.hasPrefix("T") else { continue }

            if Self.isCPUTemperatureKey(key) {
                cpuKeys.append(key)
            } else if Self.isGPUTemperatureKey(key) {
                gpuKeys.append(key)
            }
        }

        // Keep only sensors that currently report a plausible value.
        cpuTemperatureKeys = cpuKeys.filter { readSMC($0).map(Self.isPlausibleTemperature) ?? false }
        gpuTemperatureKeys = gpuKeys.filter { readSMC($0).map(Self.isPlausibleTemperature) ?? false }
        fanCount = Int(readSMC("FNum") ?? 0)
    }

    /// Apple Silicon: Tp* (performance cores) and Te* (efficiency cores).
    /// Intel: TC0P/TC0D/TC0E/TC0F (package/die) and TCnC (per core).
    private static func isCPUTemperatureKey(_ key: String) -> Bool {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return true }
        if ["TC0P", "TC0D", "TC0E", "TC0F"].contains(key) { return true }
        let chars = Array(key)
        guard chars.count == 4 else { return false }
        return chars[0] == "T" && chars[1] == "C" && chars[2].isNumber && chars[3] == "C"
    }

    /// Apple Silicon: Tg*. Intel: TG0P/TG0D.
    private static func isGPUTemperatureKey(_ key: String) -> Bool {
        key.hasPrefix("Tg") || key == "TG0P" || key == "TG0D"
    }

    private static func isPlausibleTemperature(_ value: Double) -> Bool {
        value > 5 && value < 130
    }

    private func readSMC(_ key: String) -> Double? {
        var value = 0.0
        return smc_read_double(key, &value) ? value : nil
    }

    private func readTemperature(keys: [String]) -> SystemSnapshot.Temperature? {
        let values = keys.compactMap(readSMC).filter(Self.isPlausibleTemperature)
        guard let hottest = values.max() else { return nil }
        return SystemSnapshot.Temperature(average: values.reduce(0, +) / Double(values.count), hottest: hottest)
    }

    private func readCPUTemperature() -> SystemSnapshot.Temperature? {
        if let smc = readTemperature(keys: cpuTemperatureKeys) {
            return smc
        }

        // Fallback for Macs without usable SMC keys: IOHID die sensors.
        var readings = [hid_sensor_reading](repeating: hid_sensor_reading(), count: 128)
        let count = Int(hid_read_temperatures(&readings, Int32(readings.count)))
        let values = readings.prefix(count).compactMap { reading -> Double? in
            let name = withUnsafeBytes(of: reading.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name.contains("tdie"), Self.isPlausibleTemperature(reading.value) else { return nil }
            return reading.value
        }
        guard let hottest = values.max() else { return nil }
        return SystemSnapshot.Temperature(average: values.reduce(0, +) / Double(values.count), hottest: hottest)
    }

    private func readFans() -> [SystemSnapshot.Fan] {
        (0..<fanCount).compactMap { index in
            guard let rpm = readSMC("F\(index)Ac") else { return nil }
            return SystemSnapshot.Fan(rpm: rpm, maxRPM: readSMC("F\(index)Mx"))
        }
    }

    // MARK: - GPU

    private func readGPUUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var usage: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let percent = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber
            else { continue }
            usage = max(usage ?? 0, percent.doubleValue / 100)
        }
        return usage
    }

    // MARK: - Network

    private func readNetworkCounters() -> (bytesIn: UInt64, bytesOut: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))

        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                defer { offset += Int(header.ifm_msglen) }
                guard header.ifm_msglen > 0 else { break }
                guard Int32(header.ifm_type) == RTM_IFINFO2 else { continue }

                let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard info.ifm_flags & IFF_LOOPBACK == 0, info.ifm_flags & IFF_UP != 0,
                      if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil else { continue }

                // Physical interfaces only (Wi-Fi/Ethernet/cellular) so VPN tunnels aren't counted twice.
                let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }

                bytesIn += info.ifm_data.ifi_ibytes
                bytesOut += info.ifm_data.ifi_obytes
            }
        }
        return (bytesIn, bytesOut)
    }

    private func readNetwork() -> SystemSnapshot.Network? {
        guard let counters = readNetworkCounters() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousNetwork = (counters.bytesIn, counters.bytesOut, now) }

        var downloadRate = 0.0, uploadRate = 0.0
        if let previous = previousNetwork, now > previous.time {
            let elapsed = now - previous.time
            // Counters reset when an interface goes away; treat that as zero traffic.
            if counters.bytesIn >= previous.bytesIn { downloadRate = Double(counters.bytesIn - previous.bytesIn) / elapsed }
            if counters.bytesOut >= previous.bytesOut { uploadRate = Double(counters.bytesOut - previous.bytesOut) / elapsed }
        }

        return SystemSnapshot.Network(
            downloadRate: downloadRate,
            uploadRate: uploadRate,
            totalDownloaded: counters.bytesIn,
            totalUploaded: counters.bytesOut
        )
    }

    // MARK: - Disk

    private func readDisk() -> SystemSnapshot.Disk? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return SystemSnapshot.Disk(total: UInt64(total), available: UInt64(available))
    }

    // MARK: - Battery

    private func readBattery() -> SystemSnapshot.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }

            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isOnAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (description[minutesKey] as? Int).flatMap { $0 > 0 ? $0 : nil }

            return SystemSnapshot.Battery(
                level: Double(current) / Double(maximum),
                isCharging: isCharging,
                isOnACPower: isOnAC,
                minutesRemaining: isOnAC && !isCharging ? nil : minutes,
                cycleCount: readBatteryCycleCount(),
                temperature: readSMC("TB0T").flatMap { Self.isPlausibleTemperature($0) ? $0 : nil }
            )
        }
        return nil
    }

    private func readBatteryCycleCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }
}
