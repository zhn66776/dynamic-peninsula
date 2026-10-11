import Foundation

struct SystemSensorCatalog {
    struct Key {
        let code: UInt32
        let size: UInt32
    }

    let cpuTemperatureKeys: [Key]
    let gpuTemperatureKeys: [Key]
    let fanCount: Int?

    var supportsCPUTemperature: Bool { !cpuTemperatureKeys.isEmpty }
    var supportsGPUTemperature: Bool { !gpuTemperatureKeys.isEmpty }
    var hasFanHardware: Bool { (fanCount ?? 0) > 0 }

    static func temperatureDomain(for name: String) -> String? {
        if name.hasPrefix("Tp") || name.hasPrefix("Te") { return "cpu" }
        if name.hasPrefix("Tg") { return "gpu" }
        return nil
    }

    static func aggregateTemperatures(_ values: [Double]) -> (minimum: Double, maximum: Double)? {
        let valid = values.filter { $0.isFinite && (-10...125).contains($0) }
        guard valid.count == values.count, let minimum = valid.min(), let maximum = valid.max() else {
            return nil
        }
        return (minimum, maximum)
    }
}
