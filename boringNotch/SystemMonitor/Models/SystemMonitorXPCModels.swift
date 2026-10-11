import Foundation

struct SystemMonitorXPCRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let includeGPU: Bool
    let includeTemperatures: Bool
    let includeFans: Bool
    let includeFrequencyAndPower: Bool
    let includeMemoryPressure: Bool
    let resetCapabilities: Bool

    init(
        schemaVersion: Int = currentSchemaVersion,
        includeGPU: Bool,
        includeTemperatures: Bool,
        includeFans: Bool,
        includeFrequencyAndPower: Bool,
        includeMemoryPressure: Bool = false,
        resetCapabilities: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.includeGPU = includeGPU
        self.includeTemperatures = includeTemperatures
        self.includeFans = includeFans
        self.includeFrequencyAndPower = includeFrequencyAndPower
        self.includeMemoryPressure = includeMemoryPressure
        self.resetCapabilities = resetCapabilities
    }
}

struct SystemMonitorXPCSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sampledAt: Date
    let capabilities: SystemMonitorCapabilitiesPayload
    let gpu: GPUMetricsPayload?
    let temperatures: TemperatureMetricsPayload?
    let fans: [FanMetrics]
    let diagnostics: [MetricDiagnosticPayload]
    let memoryPressureLevel: String?

    init(
        schemaVersion: Int,
        sampledAt: Date,
        capabilities: SystemMonitorCapabilitiesPayload,
        gpu: GPUMetricsPayload?,
        temperatures: TemperatureMetricsPayload?,
        fans: [FanMetrics],
        diagnostics: [MetricDiagnosticPayload],
        memoryPressureLevel: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sampledAt = sampledAt
        self.capabilities = capabilities
        self.gpu = gpu
        self.temperatures = temperatures
        self.fans = fans
        self.diagnostics = diagnostics
        self.memoryPressureLevel = memoryPressureLevel
    }

    static func decode(from data: Data) throws -> Self {
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.schemaVersion == SystemMonitorXPCRequest.currentSchemaVersion else {
            throw SystemMetricsProviderError.schemaMismatch(
                expected: SystemMonitorXPCRequest.currentSchemaVersion,
                actual: snapshot.schemaVersion
            )
        }
        return snapshot
    }
}

extension SystemMonitorXPCRequest {
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(from data: Data) throws -> Self {
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.schemaVersion == currentSchemaVersion else {
            throw SystemMetricsProviderError.schemaMismatch(
                expected: currentSchemaVersion,
                actual: request.schemaVersion
            )
        }
        return request
    }
}

struct SystemMonitorCapabilitiesPayload: Codable, Equatable, Sendable {
    let isAppleSilicon: Bool
    let chipFamily: String?
    let hasFanHardware: Bool
    let supportsAGXUtilization: Bool
    let supportsCPUTemperature: Bool
    let supportsGPUTemperature: Bool
    let supportsIOReport: Bool
    let supportsAppleSMC: Bool
}

struct GPUMetricsPayload: Codable, Equatable, Sendable {
    let utilizationPercent: Double?
    let rendererPercent: Double?
    let tilerPercent: Double?
    let memoryBytes: UInt64?
    let frequencyHz: Double?
    let powerWatts: Double?
    let source: MonitorSource?
}

struct TemperatureMetricsPayload: Codable, Equatable, Sendable {
    let cpuMaxCelsius: Double?
    let gpuMaxCelsius: Double?
    let cpuMinimumCelsius: Double?
    let gpuMinimumCelsius: Double?
    let socPowerWatts: Double?
    let source: MonitorSource?
}

struct MetricDiagnosticPayload: Codable, Equatable, Sendable {
    let domain: String
    let status: String
    let reason: String?
}

enum SystemMonitorXPCError: Error, Equatable, Sendable {
    case requestEncodingFailed
    case requestAlreadyInFlight
    case helperRejected(String)
    case invalidResponse
    case responseDecodingFailed
    case schemaMismatch(expected: Int, actual: Int)
    case transportInterrupted
    case timedOut
}
