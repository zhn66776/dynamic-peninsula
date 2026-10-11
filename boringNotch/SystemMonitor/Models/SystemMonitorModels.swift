import Foundation

enum MonitorMetricID: String, Codable, CaseIterable, Sendable {
    case cpu
    case gpu
    case thermal
    case memory
    case storage
    case network
}

enum MetricAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case failed
    case stale
}

enum MemoryPressureLevel: String, Codable, Sendable {
    case normal
    case warning
    case critical
    case unavailable
}

enum SystemThermalLevel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unavailable
}

enum MonitorSource: String, Codable, Sendable {
    case mach
    case processInfo
    case volumeResourceValues
    case ioKitStorage
    case agxRegistry
    case ioReport
    case appleSMC
}

struct MetricReading<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value?
    let availability: MetricAvailability
    let source: MonitorSource
    let sampledAt: Date

    init(
        value: Value?,
        availability: MetricAvailability,
        source: MonitorSource,
        sampledAt: Date
    ) {
        precondition(
            availability != .available || value != nil,
            "An available metric must carry a value"
        )
        self.value = value
        self.availability = availability
        self.source = source
        self.sampledAt = sampledAt
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case availability
        case source
        case sampledAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decodeIfPresent(Value.self, forKey: .value)
        let availability = try container.decode(MetricAvailability.self, forKey: .availability)
        guard availability != .available || value != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "An available metric must carry a value"
            )
        }
        self.value = value
        self.availability = availability
        source = try container.decode(MonitorSource.self, forKey: .source)
        sampledAt = try container.decode(Date.self, forKey: .sampledAt)
    }
}

extension MetricReading: Equatable where Value: Equatable {}

struct CPUMetrics: Equatable, Sendable {
    let totalPercent: MetricReading<Double>
    let performanceCorePercent: MetricReading<Double>
    let efficiencyCorePercent: MetricReading<Double>
    let logicalCoreCount: Int
    let performanceCoreCount: Int?
    let efficiencyCoreCount: Int?
    let performanceFrequencyHz: MetricReading<Double>
    let efficiencyFrequencyHz: MetricReading<Double>
    let powerWatts: MetricReading<Double>
}

struct GPUMetrics: Equatable, Sendable {
    let utilizationPercent: MetricReading<Double>
    let rendererPercent: MetricReading<Double>
    let tilerPercent: MetricReading<Double>
    let memoryBytes: MetricReading<UInt64>
    let frequencyHz: MetricReading<Double>
    let powerWatts: MetricReading<Double>
}

struct ThermalMetrics: Equatable, Sendable {
    let cpuMaxCelsius: MetricReading<Double>
    let gpuMaxCelsius: MetricReading<Double>
    let cpuRangeCelsius: ClosedRange<Double>?
    let gpuRangeCelsius: ClosedRange<Double>?
    let systemLevel: SystemThermalLevel
    let fans: [FanMetrics]
    let hasFanHardware: Bool
    let fanAvailability: MetricAvailability
    let fansSampledAt: Date?
    let socPowerWatts: MetricReading<Double>

    init(
        cpuMaxCelsius: MetricReading<Double>,
        gpuMaxCelsius: MetricReading<Double>,
        cpuRangeCelsius: ClosedRange<Double>?,
        gpuRangeCelsius: ClosedRange<Double>?,
        systemLevel: SystemThermalLevel,
        fans: [FanMetrics],
        hasFanHardware: Bool,
        fanAvailability: MetricAvailability? = nil,
        fansSampledAt: Date? = nil,
        socPowerWatts: MetricReading<Double>
    ) {
        self.cpuMaxCelsius = cpuMaxCelsius
        self.gpuMaxCelsius = gpuMaxCelsius
        self.cpuRangeCelsius = cpuRangeCelsius
        self.gpuRangeCelsius = gpuRangeCelsius
        self.systemLevel = systemLevel
        self.fans = fans
        self.hasFanHardware = hasFanHardware
        self.fanAvailability = fanAvailability
            ?? (!hasFanHardware ? .unavailable : (fans.isEmpty ? .failed : .available))
        self.fansSampledAt = fansSampledAt
        self.socPowerWatts = socPowerWatts
    }
}

struct FanMetrics: Codable, Equatable, Sendable {
    let id: Int
    let name: String
    let rpm: Double
}

struct MemoryMetrics: Equatable, Sendable {
    let pressure: MemoryPressureLevel
    let usedBytes: UInt64?
    let totalBytes: UInt64
    let cachedBytes: UInt64?
    let compressedBytes: UInt64?
    let swapUsedBytes: UInt64?
    let availability: MetricAvailability
    let sampledAt: Date

    init(
        pressure: MemoryPressureLevel,
        usedBytes: UInt64?,
        totalBytes: UInt64,
        cachedBytes: UInt64?,
        compressedBytes: UInt64?,
        swapUsedBytes: UInt64?,
        availability: MetricAvailability? = nil,
        sampledAt: Date = Date()
    ) {
        self.pressure = pressure
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.cachedBytes = cachedBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.availability = availability ?? (usedBytes == nil ? .unavailable : .available)
        self.sampledAt = sampledAt
    }
}

struct StorageMetrics: Equatable, Sendable {
    let totalBytes: UInt64?
    let availableForImportantUsageBytes: UInt64?
    let instantaneousReadBytesPerSecond: Double?
    let instantaneousWriteBytesPerSecond: Double?
    let smoothedReadBytesPerSecond: Double?
    let smoothedWriteBytesPerSecond: Double?
    let capacityAvailability: MetricAvailability
    let capacitySampledAt: Date
    let diskIOAvailability: MetricAvailability
    let diskIOSampledAt: Date

    init(
        totalBytes: UInt64?,
        availableForImportantUsageBytes: UInt64?,
        instantaneousReadBytesPerSecond: Double?,
        instantaneousWriteBytesPerSecond: Double?,
        smoothedReadBytesPerSecond: Double?,
        smoothedWriteBytesPerSecond: Double?,
        capacityAvailability: MetricAvailability? = nil,
        capacitySampledAt: Date = Date(),
        diskIOAvailability: MetricAvailability? = nil,
        diskIOSampledAt: Date = Date()
    ) {
        self.totalBytes = totalBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
        self.instantaneousReadBytesPerSecond = instantaneousReadBytesPerSecond
        self.instantaneousWriteBytesPerSecond = instantaneousWriteBytesPerSecond
        self.smoothedReadBytesPerSecond = smoothedReadBytesPerSecond
        self.smoothedWriteBytesPerSecond = smoothedWriteBytesPerSecond
        self.capacityAvailability = capacityAvailability
            ?? (totalBytes != nil && availableForImportantUsageBytes != nil ? .available : .unavailable)
        self.capacitySampledAt = capacitySampledAt
        self.diskIOAvailability = diskIOAvailability
            ?? ([instantaneousReadBytesPerSecond, instantaneousWriteBytesPerSecond,
                 smoothedReadBytesPerSecond, smoothedWriteBytesPerSecond].contains { $0 != nil }
                ? .available : .unavailable)
        self.diskIOSampledAt = diskIOSampledAt
    }
}

struct NetworkMetrics: Equatable, Sendable {
    let instantaneousDownBytesPerSecond: Double?
    let instantaneousUpBytesPerSecond: Double?
    let smoothedDownBytesPerSecond: Double?
    let smoothedUpBytesPerSecond: Double?
    let availability: MetricAvailability
    let sampledAt: Date

    init(
        instantaneousDownBytesPerSecond: Double?,
        instantaneousUpBytesPerSecond: Double?,
        smoothedDownBytesPerSecond: Double?,
        smoothedUpBytesPerSecond: Double?,
        availability: MetricAvailability? = nil,
        sampledAt: Date = Date()
    ) {
        self.instantaneousDownBytesPerSecond = instantaneousDownBytesPerSecond
        self.instantaneousUpBytesPerSecond = instantaneousUpBytesPerSecond
        self.smoothedDownBytesPerSecond = smoothedDownBytesPerSecond
        self.smoothedUpBytesPerSecond = smoothedUpBytesPerSecond
        self.availability = availability
            ?? ([instantaneousDownBytesPerSecond, instantaneousUpBytesPerSecond,
                 smoothedDownBytesPerSecond, smoothedUpBytesPerSecond].contains { $0 != nil }
                ? .available : .unavailable)
        self.sampledAt = sampledAt
    }
}

struct SystemMonitorSnapshot: Equatable, Sendable {
    let sequence: UInt64
    let sampledAt: Date
    let cpu: CPUMetrics
    let gpu: GPUMetrics
    let thermal: ThermalMetrics
    let memory: MemoryMetrics
    let storage: StorageMetrics
    let network: NetworkMetrics
    let capabilities: SystemMonitorCapabilities
}

struct SystemMonitorCapabilities: Codable, Equatable, Sendable {
    let isAppleSilicon: Bool
    let chipFamily: String?
    let hasFanHardware: Bool
    let supportsAGXUtilization: Bool
    let supportsCPUTemperature: Bool
    let supportsGPUTemperature: Bool
    let supportsIOReport: Bool
    let supportsAppleSMC: Bool
}

struct MonitorHistoryPoint: Identifiable, Equatable, Sendable {
    let id: UInt64
    let timestamp: Date
    let value: Double
}

struct SystemMonitorHistory: Equatable, Sendable {
    var cpu = FixedRingBuffer<MonitorHistoryPoint>(capacity: 60)
    var gpu = FixedRingBuffer<MonitorHistoryPoint>(capacity: 60)
    var temperature = FixedRingBuffer<MonitorHistoryPoint>(capacity: 60)
    var memory = FixedRingBuffer<MonitorHistoryPoint>(capacity: 60)
    var storageRead = FixedRingBuffer<MonitorHistoryPoint>(capacity: 60)
    var storageWrite = FixedRingBuffer<MonitorHistoryPoint>(capacity: 60)
    var networkDown = FixedRingBuffer<MonitorHistoryPoint>(capacity: 60)
    var networkUp = FixedRingBuffer<MonitorHistoryPoint>(capacity: 60)

    mutating func trim(before cutoff: Date) {
        cpu.removeAll { $0.timestamp < cutoff }
        gpu.removeAll { $0.timestamp < cutoff }
        temperature.removeAll { $0.timestamp < cutoff }
        memory.removeAll { $0.timestamp < cutoff }
        storageRead.removeAll { $0.timestamp < cutoff }
        storageWrite.removeAll { $0.timestamp < cutoff }
        networkDown.removeAll { $0.timestamp < cutoff }
        networkUp.removeAll { $0.timestamp < cutoff }
    }
}

enum SystemMetricsProviderError: Error, Equatable, Sendable {
    case unsupported(domain: String)
    case serviceNotFound(domain: String)
    case ioKitFailure(domain: String, code: Int32)
    case malformedValue(domain: String, field: String)
    case schemaMismatch(expected: Int, actual: Int)
    case transportInterrupted
    case timedOut(domain: String)
}

struct PublicMetricDomains: OptionSet, Sendable {
    let rawValue: UInt8

    static let cpu = Self(rawValue: 1 << 0)
    static let memory = Self(rawValue: 1 << 1)
    static let storage = Self(rawValue: 1 << 2)
    static let diskIO = Self(rawValue: 1 << 3)
    static let thermal = Self(rawValue: 1 << 4)
    static let network = Self(rawValue: 1 << 5)
}

struct PrivateMetricDomains: OptionSet, Sendable {
    let rawValue: UInt8

    static let gpu = Self(rawValue: 1 << 0)
    static let temperatures = Self(rawValue: 1 << 1)
    static let fans = Self(rawValue: 1 << 2)
    static let optional = Self(rawValue: 1 << 3)
    static let memoryPressure = Self(rawValue: 1 << 4)
}

struct PublicMetricsPartialSnapshot: Sendable {
    let sampledAt: Date
    let cpu: Result<CPUMetrics, SystemMetricsProviderError>?
    let memory: Result<MemoryMetrics, SystemMetricsProviderError>?
    let capacity: Result<StorageMetrics, SystemMetricsProviderError>?
    let diskIO: Result<StorageMetrics, SystemMetricsProviderError>?
    let thermal: Result<SystemThermalLevel, SystemMetricsProviderError>?
    let network: Result<NetworkMetrics, SystemMetricsProviderError>?
}
