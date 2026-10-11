import Foundation

enum SystemMetricFormatter {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.includesActualByteCount = false
        return formatter
    }()

    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", locale: .current, $0) } ?? "—"
    }

    static func celsius(_ value: Double?) -> String {
        value.map { String(format: "%.0f°C", locale: .current, $0) } ?? "—"
    }

    static func memory(used: UInt64?, total: UInt64) -> String {
        guard let used else { return "—" }
        let divisor = 1_073_741_824.0
        return String(
            format: "%.1f / %.1f GB",
            locale: .current,
            Double(used) / divisor,
            Double(total) / divisor
        )
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func storageCapacity(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return String(
            format: "%.0f GB",
            locale: .current,
            Double(value) / 1_073_741_824
        )
    }

    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let units: [(threshold: Double, divisor: Double, suffix: String)] = [
            (1_073_741_824, 1_073_741_824, "GB/s"),
            (1_048_576, 1_048_576, "MB/s"),
            (1_024, 1_024, "KB/s")
        ]
        if let unit = units.first(where: { value >= $0.threshold }) {
            return String(format: "%.1f %@", locale: .current, value / unit.divisor, unit.suffix)
        }
        return String(format: "%.0f B/s", locale: .current, value)
    }

    static func frequency(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000_000 {
            return String(format: "%.2f GHz", locale: .current, value / 1_000_000_000)
        }
        return String(format: "%.0f MHz", locale: .current, value / 1_000_000)
    }

    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.1f W", locale: .current, value)
    }
}
