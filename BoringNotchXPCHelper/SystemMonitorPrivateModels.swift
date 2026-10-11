import Foundation

struct PrivateSystemMonitorRequest: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let includeGPU: Bool
    let includeTemperatures: Bool
    let includeFans: Bool
    let includeFrequencyAndPower: Bool
    let includeMemoryPressure: Bool?
    let resetCapabilities: Bool?

    static func decode(from data: Data) throws -> Self {
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.schemaVersion == currentSchemaVersion else {
            throw PrivateSystemMonitorError.unsupportedSchema
        }
        return request
    }
}

struct PrivateSystemMonitorSnapshot: Codable {
    let schemaVersion: Int
    let sampledAt: Date
    let capabilities: PrivateSystemMonitorCapabilities
    let gpu: PrivateGPUMetrics?
    let temperatures: PrivateTemperatureMetrics?
    let fans: [PrivateFanMetrics]
    let diagnostics: [PrivateMetricDiagnostic]
    let memoryPressureLevel: String?
}

struct PrivateSystemMonitorCapabilities: Codable {
    let isAppleSilicon: Bool
    let chipFamily: String?
    let hasFanHardware: Bool
    let supportsAGXUtilization: Bool
    let supportsCPUTemperature: Bool
    let supportsGPUTemperature: Bool
    let supportsIOReport: Bool
    let supportsAppleSMC: Bool
}

struct PrivateGPUMetrics: Codable {
    let utilizationPercent: Double?
    let rendererPercent: Double?
    let tilerPercent: Double?
    let memoryBytes: UInt64?
    let frequencyHz: Double?
    let powerWatts: Double?
    let source: String?
}

struct PrivateTemperatureMetrics: Codable {
    let cpuMaxCelsius: Double?
    let gpuMaxCelsius: Double?
    let cpuMinimumCelsius: Double?
    let gpuMinimumCelsius: Double?
    let socPowerWatts: Double?
    let source: String?
}

struct PrivateFanMetrics: Codable {
    let id: Int
    let name: String
    let rpm: Double
}

struct PrivateMetricDiagnostic: Codable {
    let domain: String
    let status: String
    let reason: String?

    static func available(_ domain: String) -> Self {
        Self(domain: domain, status: "available", reason: nil)
    }

    static func unsupported(_ domain: String, _ reason: String) -> Self {
        Self(domain: domain, status: "unsupported", reason: reason)
    }

    static func failed(_ domain: String, _ reason: String) -> Self {
        Self(domain: domain, status: "failed", reason: reason)
    }
}

enum PrivateSystemMonitorError: Error {
    case unsupportedSchema
    case requestMalformed
    case responseEncodingFailed

    var code: NSString {
        switch self {
        case .unsupportedSchema: return "schemaUnsupported"
        case .requestMalformed: return "requestMalformed"
        case .responseEncodingFailed: return "responseEncodingFailed"
        }
    }
}
