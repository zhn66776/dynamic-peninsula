import Darwin
import DiskArbitration
import Foundation
import IOKit
import IOKit.storage

protocol SystemPublicMetricsProviding: Sendable {
    func sample(
        domains: PublicMetricDomains,
        at instant: ContinuousClock.Instant
    ) async -> PublicMetricsPartialSnapshot

    func resetDeltaBaselines() async
}

actor SystemPublicMetricsProvider: SystemPublicMetricsProviding {
    private var previousCPUTicks: [CPUCoreTicks]?
    private let coreTopology: CPUCoreTopology?
    private let memoryPressure = MemoryPressureTracker()
    private let thermalState = SystemThermalStateTracker()
    private var diskReader: InternalSystemDiskCounterReader?
    private var diskBindingRetry = DiskBindingRetryState()
    private var diskRateCalculator = DiskRateCalculator()
    private var networkRateCalculator = NetworkRateCalculator()

    init() {
        coreTopology = CPUCoreTopologyReader.read()
    }

    func sample(
        domains: PublicMetricDomains,
        at instant: ContinuousClock.Instant
    ) async -> PublicMetricsPartialSnapshot {
        let sampledAt = Date()
        var cpu: Result<CPUMetrics, SystemMetricsProviderError>?
        var memory: Result<MemoryMetrics, SystemMetricsProviderError>?
        var capacity: Result<StorageMetrics, SystemMetricsProviderError>?
        var diskIO: Result<StorageMetrics, SystemMetricsProviderError>?
        var thermal: Result<SystemThermalLevel, SystemMetricsProviderError>?
        var network: Result<NetworkMetrics, SystemMetricsProviderError>?

        if domains.contains(.cpu) {
            cpu = sampleCPU(at: sampledAt)
        }
        if domains.contains(.memory) {
            memory = sampleMemory(at: sampledAt)
        }
        if domains.contains(.storage) {
            capacity = sampleCapacity()
        }
        if domains.contains(.diskIO) {
            diskIO = sampleDiskIO(at: instant)
        }
        if domains.contains(.thermal) {
            thermal = .success(thermalState.currentLevel)
        }
        if domains.contains(.network) {
            network = sampleNetwork(at: instant)
        }

        return PublicMetricsPartialSnapshot(
            sampledAt: sampledAt,
            cpu: cpu,
            memory: memory,
            capacity: capacity,
            diskIO: diskIO,
            thermal: thermal,
            network: network
        )
    }

    func resetDeltaBaselines() async {
        previousCPUTicks = nil
        diskReader = nil
        diskBindingRetry.reset()
        diskRateCalculator.reset()
        networkRateCalculator.reset()
    }

    private func sampleCPU(at date: Date) -> Result<CPUMetrics, SystemMetricsProviderError> {
        let ticks: [CPUCoreTicks]
        do {
            ticks = try MachCPUTickReader.read()
        } catch let error as SystemMetricsProviderError {
            return .failure(error)
        } catch {
            return .failure(.malformedValue(domain: "cpu", field: "ticks"))
        }

        defer { previousCPUTicks = ticks }
        let delta = CPUDeltaCalculator.calculate(
            previous: previousCPUTicks,
            current: ticks,
            grouping: coreTopology?.grouping
        )
        let unavailable = MetricReading<Double>(
            value: nil,
            availability: .unavailable,
            source: .mach,
            sampledAt: date
        )
        guard let delta else {
            return .success(
                CPUMetrics(
                    totalPercent: unavailable,
                    performanceCorePercent: unavailable,
                    efficiencyCorePercent: unavailable,
                    logicalCoreCount: ticks.count,
                    performanceCoreCount: coreTopology?.performanceCoreCount,
                    efficiencyCoreCount: coreTopology?.efficiencyCoreCount,
                    performanceFrequencyHz: unavailable,
                    efficiencyFrequencyHz: unavailable,
                    powerWatts: unavailable
                )
            )
        }
        switch delta {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            let total = MetricReading(
                value: value.totalPercent,
                availability: .available,
                source: .mach,
                sampledAt: date
            )
            let performance = MetricReading(
                value: value.performancePercent,
                availability: value.performancePercent == nil ? .unavailable : .available,
                source: .mach,
                sampledAt: date
            )
            let efficiency = MetricReading(
                value: value.efficiencyPercent,
                availability: value.efficiencyPercent == nil ? .unavailable : .available,
                source: .mach,
                sampledAt: date
            )
            return .success(
                CPUMetrics(
                    totalPercent: total,
                    performanceCorePercent: performance,
                    efficiencyCorePercent: efficiency,
                    logicalCoreCount: ticks.count,
                    performanceCoreCount: coreTopology?.performanceCoreCount,
                    efficiencyCoreCount: coreTopology?.efficiencyCoreCount,
                    performanceFrequencyHz: unavailable,
                    efficiencyFrequencyHz: unavailable,
                    powerWatts: unavailable
                )
            )
        }
    }

    private func sampleMemory(at sampledAt: Date) -> Result<MemoryMetrics, SystemMetricsProviderError> {
        var pageSize: vm_size_t = 0
        let pageSizeResult = host_page_size(mach_host_self(), &pageSize)
        guard pageSizeResult == KERN_SUCCESS else {
            return .failure(.ioKitFailure(domain: "memoryPageSize", code: pageSizeResult))
        }

        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return .failure(.ioKitFailure(domain: "memory", code: result))
        }

        let pages = VMMemoryPageCounts(
            free: UInt64(info.free_count),
            active: UInt64(info.active_count),
            inactive: UInt64(info.inactive_count),
            speculative: UInt64(info.speculative_count),
            wired: UInt64(info.wire_count),
            purgeable: UInt64(info.purgeable_count),
            fileBacked: UInt64(info.external_page_count),
            compressed: UInt64(info.compressor_page_count)
        )
        let total = ProcessInfo.processInfo.physicalMemory
        switch MemoryMetricsCalculator.calculate(
            pages: pages,
            pageSize: UInt64(pageSize),
            totalBytes: total
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let composition):
            return .success(
                MemoryMetrics(
                    pressure: memoryPressure.currentLevel,
                    usedBytes: composition.used,
                    totalBytes: total,
                    cachedBytes: composition.cached,
                    compressedBytes: composition.compressed,
                    swapUsedBytes: Self.swapUsedBytes(),
                    sampledAt: sampledAt
                )
            )
        }
    }

    private func sampleCapacity() -> Result<StorageMetrics, SystemMetricsProviderError> {
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            guard let total = values.volumeTotalCapacity,
                  let available = values.volumeAvailableCapacityForImportantUsage,
                  total >= 0,
                  available >= 0,
                  available <= Int64(total) else {
                return .failure(.malformedValue(domain: "storage", field: "capacity"))
            }
            return .success(
                StorageMetrics(
                    totalBytes: UInt64(total),
                    availableForImportantUsageBytes: UInt64(available),
                    instantaneousReadBytesPerSecond: nil,
                    instantaneousWriteBytesPerSecond: nil,
                    smoothedReadBytesPerSecond: nil,
                    smoothedWriteBytesPerSecond: nil,
                    capacityAvailability: .available,
                    capacitySampledAt: Date()
                )
            )
        } catch {
            return .failure(.serviceNotFound(domain: "rootVolumeCapacity"))
        }
    }

    private func sampleDiskIO(
        at instant: ContinuousClock.Instant
    ) -> Result<StorageMetrics, SystemMetricsProviderError> {
        do {
            if diskReader == nil {
                guard diskBindingRetry.shouldAttempt(at: instant) else {
                    return .failure(.timedOut(domain: "internalSystemDiskRetry"))
                }
                diskReader = try InternalSystemDiskCounterReader()
                diskBindingRetry.recordSuccess()
            }
            guard let counters = try diskReader?.readCounters() else {
                return .failure(.serviceNotFound(domain: "internalSystemDisk"))
            }
            guard let rates = diskRateCalculator.sample(counters: counters, at: instant) else {
                return .success(
                    StorageMetrics(
                        totalBytes: nil,
                        availableForImportantUsageBytes: nil,
                        instantaneousReadBytesPerSecond: nil,
                        instantaneousWriteBytesPerSecond: nil,
                        smoothedReadBytesPerSecond: nil,
                        smoothedWriteBytesPerSecond: nil,
                        diskIOAvailability: .unavailable,
                        diskIOSampledAt: Date()
                    )
                )
            }
            return .success(
                StorageMetrics(
                    totalBytes: nil,
                    availableForImportantUsageBytes: nil,
                    instantaneousReadBytesPerSecond: rates.readBytesPerSecond,
                    instantaneousWriteBytesPerSecond: rates.writeBytesPerSecond,
                    smoothedReadBytesPerSecond: rates.smoothedReadBytesPerSecond,
                    smoothedWriteBytesPerSecond: rates.smoothedWriteBytesPerSecond,
                    diskIOAvailability: .available,
                    diskIOSampledAt: Date()
                )
            )
        } catch let error as SystemMetricsProviderError {
            diskReader = nil
            diskBindingRetry.recordFailure(at: instant)
            return .failure(error)
        } catch {
            diskReader = nil
            diskBindingRetry.recordFailure(at: instant)
            return .failure(.serviceNotFound(domain: "internalSystemDisk"))
        }
    }

    private func sampleNetwork(
        at instant: ContinuousClock.Instant
    ) -> Result<NetworkMetrics, SystemMetricsProviderError> {
        guard let counters = Self.readNetworkCounters() else {
            return .failure(.serviceNotFound(domain: "networkInterfaces"))
        }
        guard let rates = networkRateCalculator.sample(counters: counters, at: instant) else {
            return .success(
                NetworkMetrics(
                    instantaneousDownBytesPerSecond: nil,
                    instantaneousUpBytesPerSecond: nil,
                    smoothedDownBytesPerSecond: nil,
                    smoothedUpBytesPerSecond: nil,
                    availability: .unavailable,
                    sampledAt: Date()
                )
            )
        }
        return .success(
            NetworkMetrics(
                instantaneousDownBytesPerSecond: rates.downBytesPerSecond,
                instantaneousUpBytesPerSecond: rates.upBytesPerSecond,
                smoothedDownBytesPerSecond: rates.smoothedDownBytesPerSecond,
                smoothedUpBytesPerSecond: rates.smoothedUpBytesPerSecond,
                availability: .available,
                sampledAt: Date()
            )
        )
    }

    // Sums byte counters across active, non-loopback interfaces (Wi-Fi/Ethernet
    // typically en0/en1, plus any others currently up) rather than picking one
    // by name — interface naming isn't stable across Macs/dongles, and this
    // still gives a meaningful system-wide throughput number.
    private static func readNetworkCounters() -> NetworkCounters? {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return nil }
        defer { freeifaddrs(first) }

        var down: UInt64 = 0
        var up: UInt64 = 0
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let dataPointer = entry.pointee.ifa_data else { continue }
            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(data.ifi_ibytes)
            up += UInt64(data.ifi_obytes)
        }
        return NetworkCounters(downBytes: down, upBytes: up)
    }

    private static func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return result == 0 ? usage.xsu_used : nil
    }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> SystemThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unavailable
        }
    }
}

private enum MachCPUTickReader {
    static func read() throws -> [CPUCoreTicks] {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )
        guard result == KERN_SUCCESS, let cpuInfo else {
            throw SystemMetricsProviderError.ioKitFailure(domain: "cpuTicks", code: result)
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: cpuInfo)),
                vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { core in
            let base = core * stride
            return CPUCoreTicks(
                user: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)]),
                nice: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)]),
                idle: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)])
            )
        }
    }
}

private struct CPUCoreTopology: Sendable {
    let grouping: CPUCoreGrouping
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int
}

private enum CPUCoreTopologyReader {
    static func read() -> CPUCoreTopology? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var performance: [Int] = []
        var efficiency: [Int] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard let logicalID = integerProperty("logical-cpu-id", entry: entry),
                  let clusterType = stringProperty("cluster-type", entry: entry) else {
                continue
            }
            switch clusterType {
            case "P": performance.append(logicalID)
            case "E": efficiency.append(logicalID)
            default: continue
            }
        }

        let grouping = CPUCoreGrouping(
            performanceIndices: performance.sorted(),
            efficiencyIndices: efficiency.sorted()
        )
        guard grouping.isComplete else { return nil }
        return CPUCoreTopology(
            grouping: grouping,
            performanceCoreCount: performance.count,
            efficiencyCoreCount: efficiency.count
        )
    }

    private static func integerProperty(_ key: String, entry: io_registry_entry_t) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        guard let data = value as? Data, data.count >= 4 else { return nil }
        return data.prefix(4).enumerated().reduce(0) { result, byte in
            result | (Int(byte.element) << (byte.offset * 8))
        }
    }

    private static func stringProperty(_ key: String, entry: io_registry_entry_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return nil }
        if let string = value as? String { return string }
        guard let data = value as? Data else { return nil }
        return String(data: data.prefix { $0 != 0 }, encoding: .utf8)
    }
}

private final class MemoryPressureTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var level: MemoryPressureLevel = .unavailable
    private var source: DispatchSourceMemoryPressure?

    init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "theboringteam.boringnotch.memory-pressure")
        )
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let data = source.data
            guard let next = MemoryPressureLevelMapper.level(for: data) else { return }
            self.lock.lock()
            self.level = next
            self.lock.unlock()
        }
        source.activate()
    }

    deinit {
        source?.cancel()
    }

    var currentLevel: MemoryPressureLevel {
        lock.lock()
        defer { lock.unlock() }
        return level
    }
}

enum MemoryPressureLevelMapper {
    static func level(for event: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel? {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        if event.contains(.normal) { return .normal }
        return nil
    }
}

private final class SystemThermalStateTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var level: SystemThermalLevel
    private var observer: NSObjectProtocol?

    init() {
        level = SystemPublicMetricsProvider.thermalLevel(ProcessInfo.processInfo.thermalState)
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: ProcessInfo.processInfo,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let next = SystemPublicMetricsProvider.thermalLevel(ProcessInfo.processInfo.thermalState)
            self.lock.lock()
            self.level = next
            self.lock.unlock()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var currentLevel: SystemThermalLevel {
        lock.lock()
        defer { lock.unlock() }
        return level
    }
}

private final class InternalSystemDiskCounterReader: @unchecked Sendable {
    private let statisticsService: io_registry_entry_t

    init() throws {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(
                kCFAllocatorDefault,
                session,
                URL(fileURLWithPath: "/") as CFURL
              ),
              let description = DADiskCopyDescription(disk) as? [CFString: Any],
              let bsdName = description[kDADiskDescriptionMediaBSDNameKey] as? String,
              description[kDADiskDescriptionDeviceInternalKey] as? Bool == true else {
            throw SystemMetricsProviderError.serviceNotFound(domain: "rootVolumeDisk")
        }

        let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName)
        var current = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard current != 0 else {
            throw SystemMetricsProviderError.serviceNotFound(domain: "rootVolumeMedia")
        }

        var verifiedInternalWholeDisk = false
        var selected: io_registry_entry_t = 0
        while current != 0 {
            let whole = Self.boolProperty(kIOMediaWholeKey as String, entry: current)
            if whole == true {
                guard let wholeBSDName = Self.stringProperty(kIOBSDNameKey as String, entry: current),
                      Self.isInternalWholeDisk(session: session, bsdName: wholeBSDName) else {
                    IOObjectRelease(current)
                    throw SystemMetricsProviderError.unsupported(domain: "externalRootDisk")
                }
                verifiedInternalWholeDisk = true
            }

            if verifiedInternalWholeDisk, Self.statistics(entry: current) != nil {
                selected = current
                break
            }

            var parent: io_registry_entry_t = 0
            let parentResult = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            current = parentResult == KERN_SUCCESS ? parent : 0
        }

        guard verifiedInternalWholeDisk, selected != 0 else {
            throw SystemMetricsProviderError.serviceNotFound(domain: "internalWholeDiskStatistics")
        }
        statisticsService = selected
    }

    deinit {
        IOObjectRelease(statisticsService)
    }

    func readCounters() throws -> DiskCounters {
        guard let statistics = Self.statistics(entry: statisticsService),
              let read = Self.unsignedValue(statistics["Bytes (Read)"]),
              let written = Self.unsignedValue(statistics["Bytes (Write)"]) else {
            throw SystemMetricsProviderError.malformedValue(
                domain: "internalSystemDisk",
                field: "statistics"
            )
        }
        return DiskCounters(readBytes: read, writtenBytes: written)
    }

    private static func boolProperty(_ key: String, entry: io_registry_entry_t) -> Bool? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool
    }

    private static func stringProperty(_ key: String, entry: io_registry_entry_t) -> String? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }

    private static func isInternalWholeDisk(session: DASession, bsdName: String) -> Bool {
        let disk = bsdName.withCString { name in
            DADiskCreateFromBSDName(kCFAllocatorDefault, session, name)
        }
        guard let disk,
              let description = DADiskCopyDescription(disk) as? [CFString: Any] else {
            return false
        }
        return SystemDiskIdentityValidator.isInternalWhole(
            mediaWhole: description[kDADiskDescriptionMediaWholeKey] as? Bool,
            deviceInternal: description[kDADiskDescriptionDeviceInternalKey] as? Bool
        )
    }

    private static func statistics(entry: io_registry_entry_t) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(
            entry,
            kIOBlockStorageDriverStatisticsKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any]
    }

    private static func unsignedValue(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, number.int64Value >= 0 else { return nil }
        return number.uint64Value
    }
}
