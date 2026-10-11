import Foundation

final class SystemMonitorPrivateMetricsProvider {
    private let queue = DispatchQueue(
        label: "theboringteam.boringnotch.system-monitor",
        qos: .utility
    )
    private var agxReader: AGXMetricsReader?
    private var agxInitializationReason: String?
    private var ioReportReader: IOReportMetricsReader
    private var smcReader: AppleSMCReader?
    private var smcInitializationReason: String?

    init() {
        do {
            agxReader = try AGXMetricsReader()
            agxInitializationReason = nil
        } catch {
            agxReader = nil
            agxInitializationReason = "agxInitializationFailed"
        }
        ioReportReader = IOReportMetricsReader()
        do {
            smcReader = try AppleSMCReader()
            smcInitializationReason = nil
        } catch {
            smcReader = nil
            smcInitializationReason = "appleSMCInitializationFailed"
        }
    }

    func reset(completion: @escaping () -> Void) {
        queue.async { [self] in
            do {
                agxReader = try AGXMetricsReader()
                agxInitializationReason = nil
            } catch {
                agxReader = nil
                agxInitializationReason = "agxInitializationFailed"
            }
            ioReportReader = IOReportMetricsReader()
            do {
                smcReader = try AppleSMCReader()
                smcInitializationReason = nil
            } catch {
                smcReader = nil
                smcInitializationReason = "appleSMCInitializationFailed"
            }
            completion()
        }
    }

    func sample(
        request: PrivateSystemMonitorRequest,
        completion: @escaping (PrivateSystemMonitorSnapshot) -> Void
    ) {
        queue.async { [self] in
            let sampledAt = Date()
            var diagnostics = [PrivateMetricDiagnostic]()
            let gpu = request.includeGPU ? readGPU(diagnostics: &diagnostics) : nil
            let temperatures = request.includeTemperatures
                ? readTemperatures(diagnostics: &diagnostics)
                : nil
            let fans = request.includeFans ? readFans(diagnostics: &diagnostics) : []

            if request.includeFrequencyAndPower {
                diagnostics.append(.unsupported("frequencyAndPower", "notEnabledInPhase4"))
            }
            let memoryPressure = request.includeMemoryPressure == true
                ? readMemoryPressure(diagnostics: &diagnostics)
                : nil

            let catalog = smcReader?.catalog
            completion(PrivateSystemMonitorSnapshot(
                schemaVersion: PrivateSystemMonitorRequest.currentSchemaVersion,
                sampledAt: sampledAt,
                capabilities: PrivateSystemMonitorCapabilities(
                    isAppleSilicon: Self.isAppleSilicon,
                    chipFamily: Self.chipFamily(),
                    hasFanHardware: catalog?.hasFanHardware ?? false,
                    supportsAGXUtilization: agxReader != nil,
                    supportsCPUTemperature: catalog?.supportsCPUTemperature ?? false,
                    supportsGPUTemperature: catalog?.supportsGPUTemperature ?? false,
                    supportsIOReport: ioReportReader.isAvailable,
                    supportsAppleSMC: smcReader != nil
                ),
                gpu: gpu,
                temperatures: temperatures,
                fans: fans,
                diagnostics: diagnostics,
                memoryPressureLevel: memoryPressure
            ))
        }
    }

    private func readGPU(
        diagnostics: inout [PrivateMetricDiagnostic]
    ) -> PrivateGPUMetrics? {
        guard let agxReader else {
            diagnostics.append(.failed(
                "gpuAGX",
                agxInitializationReason ?? "agxInitializationFailed"
            ))
            return readIOReportGPU(diagnostics: &diagnostics)
        }
        do {
            let sample = try agxReader.read()
            diagnostics.append(contentsOf: sample.diagnostics)
            return PrivateGPUMetrics(
                utilizationPercent: sample.devicePercent,
                rendererPercent: sample.rendererPercent,
                tilerPercent: sample.tilerPercent,
                memoryBytes: sample.memoryBytes,
                frequencyHz: nil,
                powerWatts: nil,
                source: "agxRegistry"
            )
        } catch {
            diagnostics.append(.failed("gpuAGX", "agxReadFailed"))
            return readIOReportGPU(diagnostics: &diagnostics)
        }
    }

    private func readIOReportGPU(
        diagnostics: inout [PrivateMetricDiagnostic]
    ) -> PrivateGPUMetrics? {
        do {
            let utilization = try ioReportReader.readGPUUtilizationPercent()
            diagnostics.append(.available("gpu"))
            diagnostics.append(.unsupported("gpuRenderer", "agxUnavailable"))
            diagnostics.append(.unsupported("gpuTiler", "agxUnavailable"))
            diagnostics.append(.unsupported("gpuMemory", "agxUnavailable"))
            return PrivateGPUMetrics(
                utilizationPercent: utilization,
                rendererPercent: nil,
                tilerPercent: nil,
                memoryBytes: nil,
                frequencyHz: nil,
                powerWatts: nil,
                source: "ioReport"
            )
        } catch {
            diagnostics.append(.failed("gpu", "agxAndIOReportUnavailable"))
            return nil
        }
    }

    private func readTemperatures(
        diagnostics: inout [PrivateMetricDiagnostic]
    ) -> PrivateTemperatureMetrics? {
        guard let smcReader else {
            diagnostics.append(.failed(
                "cpuTemperature",
                smcInitializationReason ?? "appleSMCUnavailable"
            ))
            diagnostics.append(.unsupported("gpuTemperature", ioReportReader.temperatureStatusReason))
            return nil
        }
        let sample = smcReader.readTemperatures()
        let cpu = SystemSensorCatalog.aggregateTemperatures(sample.cpu)
        let gpu = SystemSensorCatalog.aggregateTemperatures(sample.gpu)

        diagnostics.append(cpu == nil
            ? .failed("cpuTemperature", "noValidSensor")
            : .available("cpuTemperature"))
        diagnostics.append(gpu == nil
            ? .failed("gpuTemperature", "noValidSensor")
            : .available("gpuTemperature"))
        if sample.invalidCPUCount > 0 {
            diagnostics.append(.failed("cpuTemperatureSensors", "partialSensorFailure"))
        }
        if sample.invalidGPUCount > 0 {
            diagnostics.append(.failed("gpuTemperatureSensors", "partialSensorFailure"))
        }
        guard cpu != nil || gpu != nil else { return nil }
        return PrivateTemperatureMetrics(
            cpuMaxCelsius: cpu?.maximum,
            gpuMaxCelsius: gpu?.maximum,
            cpuMinimumCelsius: cpu?.minimum,
            gpuMinimumCelsius: gpu?.minimum,
            socPowerWatts: nil,
            source: "appleSMC"
        )
    }

    private func readFans(
        diagnostics: inout [PrivateMetricDiagnostic]
    ) -> [PrivateFanMetrics] {
        guard let smcReader else {
            diagnostics.append(.failed("fans", "appleSMCUnavailable"))
            return []
        }
        guard let count = smcReader.catalog.fanCount else {
            diagnostics.append(.failed("fans", "fanCountUnavailable"))
            return []
        }
        guard count > 0 else {
            diagnostics.append(.unsupported("fans", "noFanHardware"))
            return []
        }
        do {
            let fans = try smcReader.readFans()
            diagnostics.append(.available("fans"))
            return fans
        } catch {
            diagnostics.append(.failed("fans", "fanReadFailed"))
            return []
        }
    }

    private func readMemoryPressure(
        diagnostics: inout [PrivateMetricDiagnostic]
    ) -> String? {
        var raw: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &raw, &size, nil, 0) == 0 else {
            diagnostics.append(.unsupported("memoryPressure", "sysctlUnavailable"))
            return nil
        }
        let level: String?
        switch raw {
        case 1: level = "normal"
        case 2: level = "warning"
        case 4: level = "critical"
        default: level = nil
        }
        if level == nil {
            diagnostics.append(.failed("memoryPressure", "unexpectedLevel"))
        } else {
            diagnostics.append(.available("memoryPressure"))
        }
        return level
    }

    private static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private static func chipFamily() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        let brand = String(cString: bytes)
        return ["M1", "M2", "M3", "M4", "M5"].first { brand.contains($0) }
    }
}
