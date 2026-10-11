import Foundation
import IOKit

struct AGXMetricsSample {
    let devicePercent: Double
    let rendererPercent: Double?
    let tilerPercent: Double?
    let memoryBytes: UInt64?
    let diagnostics: [PrivateMetricDiagnostic]
}

enum AGXMetricsReaderError: Error {
    case serviceNotFound
    case statisticsUnavailable
    case malformedDeviceUtilization
}

final class AGXMetricsReader {
    private var service: io_service_t

    init() throws {
        service = try Self.locateService()
    }

    deinit {
        IOObjectRelease(service)
    }

    func read() throws -> AGXMetricsSample {
        guard let statistics = statisticsDictionary() else {
            let replacement = try Self.locateService()
            IOObjectRelease(service)
            service = replacement
            guard let statistics = statisticsDictionary() else {
                throw AGXMetricsReaderError.statisticsUnavailable
            }
            return try Self.decode(statistics)
        }
        return try Self.decode(statistics)
    }

    private func statisticsDictionary() -> [String: Any]? {
        IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any]
    }

    private static func locateService() throws -> io_service_t {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        )
        guard result == kIOReturnSuccess else {
            throw AGXMetricsReaderError.serviceNotFound
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let candidate = IOIteratorNext(iterator)
            guard candidate != 0 else { break }
            let ioClass = IORegistryEntryCreateCFProperty(
                candidate,
                "IOClass" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String
            if ioClass?.localizedCaseInsensitiveContains("AGX") == true {
                return candidate
            }
            IOObjectRelease(candidate)
        }
        throw AGXMetricsReaderError.serviceNotFound
    }

    private static func decode(_ statistics: [String: Any]) throws -> AGXMetricsSample {
        guard let device = validPercent(statistics["Device Utilization %"]) else {
            throw AGXMetricsReaderError.malformedDeviceUtilization
        }

        var diagnostics = [PrivateMetricDiagnostic.available("gpu")]
        let renderer = optionalPercent(
            statistics["Renderer Utilization %"],
            domain: "gpuRenderer",
            diagnostics: &diagnostics
        )
        let tiler = optionalPercent(
            statistics["Tiler Utilization %"],
            domain: "gpuTiler",
            diagnostics: &diagnostics
        )
        let memory = optionalMemoryBytes(
            statistics["In use system memory"],
            diagnostics: &diagnostics
        )
        return AGXMetricsSample(
            devicePercent: device,
            rendererPercent: renderer,
            tilerPercent: tiler,
            memoryBytes: memory,
            diagnostics: diagnostics
        )
    }

    private static func validPercent(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private static func optionalPercent(
        _ raw: Any?,
        domain: String,
        diagnostics: inout [PrivateMetricDiagnostic]
    ) -> Double? {
        guard raw != nil else {
            diagnostics.append(.unsupported(domain, "fieldUnavailable"))
            return nil
        }
        guard let value = validPercent(raw) else {
            diagnostics.append(.failed(domain, "malformedValue"))
            return nil
        }
        diagnostics.append(.available(domain))
        return value
    }

    private static func optionalMemoryBytes(
        _ raw: Any?,
        diagnostics: inout [PrivateMetricDiagnostic]
    ) -> UInt64? {
        guard raw is NSNumber else {
            diagnostics.append(.unsupported("gpuMemory", "fieldUnavailable"))
            return nil
        }
        // A current-M3 allocation experiment did not make this raw counter
        // track known-size Metal buffers. Until its unit and semantics are
        // independently established, exposing it as bytes would be fabricated.
        diagnostics.append(.unsupported("gpuMemory", "unitUnverified"))
        return nil
    }
}
