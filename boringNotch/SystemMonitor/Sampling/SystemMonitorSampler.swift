import Foundation

protocol SystemPrivateMetricsProviding: Sendable {
    func sample(domains: PrivateMetricDomains) async throws -> SystemMonitorXPCSnapshot
    func resetCapabilities() async
}

actor SystemPrivateMetricsClient: SystemPrivateMetricsProviding {
    private var resetOnNextRequest = false

    func sample(domains: PrivateMetricDomains) async throws -> SystemMonitorXPCSnapshot {
        let request = SystemMonitorXPCRequest(
            includeGPU: domains.contains(.gpu),
            includeTemperatures: domains.contains(.temperatures),
            includeFans: domains.contains(.fans),
            includeFrequencyAndPower: domains.contains(.optional),
            includeMemoryPressure: domains.contains(.memoryPressure),
            resetCapabilities: resetOnNextRequest
        )
        resetOnNextRequest = false
        return try await XPCHelperClient.shared.systemMonitorSnapshot(request: request)
    }

    func resetCapabilities() async {
        resetOnNextRequest = true
    }
}

protocol SystemMonitorClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

struct LiveSystemMonitorClock: SystemMonitorClock {
    private let clock = ContinuousClock()

    var now: ContinuousClock.Instant { clock.now }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await clock.sleep(until: deadline)
    }
}

struct SystemMonitorSamplerStatistics: Equatable, Sendable {
    var completedSamples: UInt64 = 0
    var skippedSamples: UInt64 = 0
    var privateTimeouts: UInt64 = 0
    var privateRequests: UInt64 = 0
    var backoffLevel = 0
}

actor SystemMonitorSampler {
    static let shared = SystemMonitorSampler(
        publicProvider: SystemPublicMetricsProvider(),
        privateProvider: SystemPrivateMetricsClient()
    )

    private let publicProvider: any SystemPublicMetricsProviding
    private let privateProvider: any SystemPrivateMetricsProviding
    private let clock: any SystemMonitorClock
    private let currentDate: @Sendable () -> Date

    private var loopTask: Task<Void, Never>?
    private var isStarted = false
    private var continuation: AsyncStream<SystemMonitorSnapshot>.Continuation?
    private var context: SamplingContext = .disabled
    private var lowPowerMode = false
    private var deadlines: [SamplingDomain: ContinuousClock.Instant] = [:]
    private var isSampling = false
    private var sequence: UInt64 = 0
    private var snapshot = SystemMonitorSnapshot.placeholder()
    private var backoff = SamplingBackoffState()
    private var statistics = SystemMonitorSamplerStatistics()
    private var memoryPressureFallbackAttempted = false
    private var sampleImmediatelyWhenActive = false
    private var unsupportedPrivateDomains = PrivateMetricDomains()

    init(
        publicProvider: any SystemPublicMetricsProviding,
        privateProvider: any SystemPrivateMetricsProviding,
        clock: any SystemMonitorClock = LiveSystemMonitorClock(),
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.publicProvider = publicProvider
        self.privateProvider = privateProvider
        self.clock = clock
        self.currentDate = currentDate
    }

    func snapshots() -> AsyncStream<SystemMonitorSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation?.finish()
            self.continuation = continuation
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        scheduleEnabledDomains(immediately: true, at: clock.now)
        startLoopIfNeeded()
    }

    func stop() async {
        loopTask?.cancel()
        loopTask = nil
        isStarted = false
        while isSampling {
            await Task.yield()
        }
        continuation?.finish()
        continuation = nil
        deadlines.removeAll()
    }

    func setContext(_ newContext: SamplingContext) {
        guard context != newContext else { return }
        let wasForeground = context == .foreground
        context = newContext
        let becameActive = newContext == .foreground || newContext == .background
        let immediately = (newContext == .foreground && !wasForeground)
            || (becameActive && sampleImmediatelyWhenActive)
        if becameActive { sampleImmediatelyWhenActive = false }
        scheduleEnabledDomains(
            immediately: immediately,
            at: clock.now
        )
        if isStarted { restartLoop() }
    }

    func setLowPowerMode(_ enabled: Bool) {
        guard lowPowerMode != enabled else { return }
        lowPowerMode = enabled
        scheduleEnabledDomains(immediately: false, at: clock.now)
        if isStarted { restartLoop() }
    }

    func handleWake() async {
        await publicProvider.resetDeltaBaselines()
        await privateProvider.resetCapabilities()
        memoryPressureFallbackAttempted = false
        unsupportedPrivateDomains = []
        sampleImmediatelyWhenActive = true
        snapshot = snapshot.removingDeltaValues(at: currentDate())
        if context == .foreground || context == .background {
            sampleImmediatelyWhenActive = false
            scheduleEnabledDomains(immediately: true, at: clock.now)
        }
        if isStarted { restartLoop() }
    }

    func currentStatistics() -> SystemMonitorSamplerStatistics {
        statistics
    }

    func sampleIfDue(at instant: ContinuousClock.Instant) async {
        let policy = currentPolicy
        let due = SamplingDomain.allCases.filter {
            guard policy.interval(for: $0) != nil, let deadline = deadlines[$0] else { return false }
            return deadline <= instant
        }
        guard !due.isEmpty else { return }

        if isSampling {
            statistics.skippedSamples += 1
            advanceDeadlines(for: due, from: instant, policy: policy)
            return
        }

        isSampling = true
        defer { isSampling = false }
        advanceDeadlines(for: due, from: instant, policy: policy)

        let publicDomains = Self.publicDomains(for: due)
        let privateDomains = privateDomains(for: due)
        let transactionStart = clock.now
        let publicPartial = await publicProvider.sample(domains: publicDomains, at: instant)

        var privatePartial: Result<SystemMonitorXPCSnapshot, SystemMonitorXPCError>?
        var privateDuration = Duration.zero
        if !privateDomains.isEmpty {
            statistics.privateRequests += 1
            let privateStart = clock.now
            do {
                privatePartial = .success(try await privateProvider.sample(domains: privateDomains))
            } catch let error as SystemMonitorXPCError {
                privatePartial = .failure(error)
                if error == .timedOut { statistics.privateTimeouts += 1 }
            } catch {
                privatePartial = .failure(.transportInterrupted)
            }
            privateDuration = clock.now - privateStart
            if case .success(let payload) = privatePartial {
                updatePrivateCapabilities(from: payload, requested: privateDomains)
            }
        }

        sequence += 1
        snapshot = SystemMonitorSnapshotMerger.merge(
            previous: snapshot,
            sequence: sequence,
            sampledAt: currentDate(),
            due: Set(due),
            publicPartial: publicPartial,
            privatePartial: privatePartial
        )
        snapshot = snapshot.markingStale(at: currentDate(), policy: policy)
        continuation?.yield(snapshot)
        statistics.completedSamples += 1

        let totalDuration = clock.now - transactionStart
        let totalLimit: Duration = context == .foreground ? .milliseconds(150) : .milliseconds(75)
        let privateLimit: Duration = context == .foreground ? .milliseconds(100) : .milliseconds(50)
        let oldLevel = backoff.level
        backoff.record(
            overBudget: totalDuration > totalLimit || privateDuration > privateLimit,
            at: instant
        )
        statistics.backoffLevel = backoff.level
        if oldLevel != backoff.level {
            scheduleEnabledDomains(immediately: false, at: instant)
            #if DEBUG
            NSLog("System monitor backoff changed to level %d", backoff.level)
            #endif
        }
    }

    private var currentPolicy: SystemMonitorSamplingPolicy {
        SystemMonitorSamplingPolicy(
            context: context,
            isLowPowerMode: lowPowerMode,
            backoffLevel: backoff.level
        )
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard let next = deadlines.values.min() else { return }
            do {
                try await clock.sleep(until: next)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await sampleIfDue(at: clock.now)
        }
    }

    private func startLoopIfNeeded() {
        guard loopTask == nil, !deadlines.isEmpty else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = nil
        startLoopIfNeeded()
    }

    private func scheduleEnabledDomains(
        immediately: Bool,
        at instant: ContinuousClock.Instant
    ) {
        let policy = currentPolicy
        for domain in SamplingDomain.allCases {
            guard let interval = policy.interval(for: domain) else {
                deadlines[domain] = nil
                continue
            }
            if immediately || deadlines[domain] == nil {
                deadlines[domain] = immediately ? instant : instant.advanced(by: interval)
            } else {
                deadlines[domain] = instant.advanced(by: interval)
            }
        }
    }

    private func advanceDeadlines(
        for domains: [SamplingDomain],
        from instant: ContinuousClock.Instant,
        policy: SystemMonitorSamplingPolicy
    ) {
        for domain in domains {
            guard let interval = policy.interval(for: domain) else {
                deadlines[domain] = nil
                continue
            }
            var next = deadlines[domain] ?? instant
            repeat {
                next = next.advanced(by: interval)
            } while next <= instant
            deadlines[domain] = next
        }
    }

    private static func publicDomains(for due: [SamplingDomain]) -> PublicMetricDomains {
        due.reduce(into: PublicMetricDomains()) { result, domain in
            switch domain {
            case .cpu: result.insert(.cpu)
            case .memory: result.insert(.memory)
            case .capacity: result.insert(.storage)
            case .diskIO: result.insert(.diskIO)
            case .temperature: result.insert(.thermal)
            case .network: result.insert(.network)
            case .gpu, .fans, .optional: break
            }
        }
    }

    private func privateDomains(for due: [SamplingDomain]) -> PrivateMetricDomains {
        due.reduce(into: PrivateMetricDomains()) { result, domain in
            switch domain {
            case .gpu:
                if !unsupportedPrivateDomains.contains(.gpu) {
                    result.insert(.gpu)
                }
            case .temperature:
                if !unsupportedPrivateDomains.contains(.temperatures) {
                    result.insert(.temperatures)
                }
            case .fans:
                if !unsupportedPrivateDomains.contains(.fans) {
                    result.insert(.fans)
                }
            case .optional:
                break
            case .memory:
                if snapshot.memory.pressure == .unavailable && !memoryPressureFallbackAttempted {
                    result.insert(.memoryPressure)
                }
            case .cpu, .capacity, .diskIO, .network: break
            }
        }
    }

    private func updatePrivateCapabilities(
        from payload: SystemMonitorXPCSnapshot,
        requested: PrivateMetricDomains
    ) {
        if requested.contains(.gpu) {
            if payload.gpu != nil {
                unsupportedPrivateDomains.remove(.gpu)
            } else if payload.diagnostics.contains(where: {
                $0.domain == "gpu" && $0.status == "unsupported"
            }) {
                unsupportedPrivateDomains.insert(.gpu)
            }
        }
        if requested.contains(.temperatures) {
            if payload.temperatures != nil {
                unsupportedPrivateDomains.remove(.temperatures)
            } else {
                let unsupported = Set(payload.diagnostics.filter {
                    $0.status == "unsupported"
                }.map(\.domain))
                if unsupported.contains("cpuTemperature")
                    && unsupported.contains("gpuTemperature") {
                    unsupportedPrivateDomains.insert(.temperatures)
                }
            }
        }
        if requested.contains(.fans) {
            if payload.capabilities.hasFanHardware || payload.diagnostics.contains(where: {
                $0.domain == "fans" && $0.status == "available"
            }) {
                unsupportedPrivateDomains.remove(.fans)
            } else if payload.diagnostics.contains(where: {
                $0.domain == "fans" && $0.status == "unsupported"
            }) {
                unsupportedPrivateDomains.insert(.fans)
            }
        }
        if requested.contains(.memoryPressure) {
            memoryPressureFallbackAttempted = true
        }
    }
}

private enum SystemMonitorSnapshotMerger {
    static func merge(
        previous: SystemMonitorSnapshot,
        sequence: UInt64,
        sampledAt: Date,
        due: Set<SamplingDomain>,
        publicPartial: PublicMetricsPartialSnapshot,
        privatePartial: Result<SystemMonitorXPCSnapshot, SystemMonitorXPCError>?
    ) -> SystemMonitorSnapshot {
        var cpu = previous.cpu
        var gpu = previous.gpu
        var thermal = previous.thermal
        var memory = previous.memory
        var storage = previous.storage
        var network = previous.network
        var capabilities = previous.capabilities

        if due.contains(.cpu), let result = publicPartial.cpu {
            cpu = result.value ?? cpu.failed(at: sampledAt)
        }
        if due.contains(.memory), let result = publicPartial.memory {
            if let value = result.value {
                memory = value.pressure == .unavailable && memory.pressure != .unavailable
                    ? value.withPressure(memory.pressure)
                    : value
            } else {
                memory = MemoryMetrics(
                    pressure: .unavailable,
                    usedBytes: nil,
                    totalBytes: previous.memory.totalBytes,
                    cachedBytes: nil,
                    compressedBytes: nil,
                    swapUsedBytes: nil,
                    availability: .failed,
                    sampledAt: sampledAt
                )
            }
        }
        if due.contains(.capacity), let result = publicPartial.capacity {
            if let value = result.value {
                storage = storage.mergingCapacity(value)
            } else {
                storage = storage.clearingCapacity(at: sampledAt)
            }
        }
        if due.contains(.diskIO), let result = publicPartial.diskIO {
            if let value = result.value {
                storage = storage.mergingRates(value)
            } else {
                storage = storage.clearingRates(at: sampledAt)
            }
        }
        if due.contains(.temperature), let result = publicPartial.thermal,
           let level = result.value {
            thermal = thermal.withSystemLevel(level)
        }
        if due.contains(.network), let result = publicPartial.network {
            network = result.value ?? NetworkMetrics(
                instantaneousDownBytesPerSecond: nil,
                instantaneousUpBytesPerSecond: nil,
                smoothedDownBytesPerSecond: nil,
                smoothedUpBytesPerSecond: nil,
                availability: .failed,
                sampledAt: sampledAt
            )
        }

        if let privatePartial {
            switch privatePartial {
            case .success(let payload):
                capabilities = payload.capabilities.model
                if due.contains(.gpu) {
                    gpu = GPUMetrics(payload: payload.gpu, diagnostics: payload.diagnostics, at: payload.sampledAt)
                }
                if due.contains(.temperature) {
                    thermal = thermal.mergingTemperatures(
                        payload.temperatures,
                        diagnostics: payload.diagnostics,
                        at: payload.sampledAt
                    )
                }
                if due.contains(.fans) {
                    thermal = thermal.mergingFans(
                        payload.fans,
                        diagnostics: payload.diagnostics,
                        capabilities: capabilities,
                        at: payload.sampledAt
                    )
                }
                if due.contains(.memory), memory.pressure == .unavailable,
                   let pressure = MemoryPressureLevel(rawValue: payload.memoryPressureLevel ?? "") {
                    memory = memory.withPressure(pressure)
                }
            case .failure:
                if due.contains(.gpu) { gpu = gpu.failed(at: sampledAt) }
                if due.contains(.temperature) { thermal = thermal.failedTemperatures(at: sampledAt) }
                if due.contains(.fans) { thermal = thermal.clearingFailedFans(at: sampledAt) }
            }
        }

        return SystemMonitorSnapshot(
            sequence: sequence,
            sampledAt: sampledAt,
            cpu: cpu,
            gpu: gpu,
            thermal: thermal,
            memory: memory,
            storage: storage,
            network: network,
            capabilities: capabilities
        )
    }
}

private extension Result {
    var value: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}

private extension MemoryMetrics {
    func withPressure(_ pressure: MemoryPressureLevel) -> Self {
        return Self(
            pressure: pressure,
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            cachedBytes: cachedBytes,
            compressedBytes: compressedBytes,
            swapUsedBytes: swapUsedBytes,
            availability: availability,
            sampledAt: sampledAt
        )
    }
}

extension SystemMonitorSnapshot {
    static func placeholder(at date: Date = Date()) -> Self {
        let unavailableMach = MetricReading<Double>(
            value: nil, availability: .unavailable, source: .mach, sampledAt: date
        )
        let unavailableAGX = MetricReading<Double>(
            value: nil, availability: .unavailable, source: .agxRegistry, sampledAt: date
        )
        let unavailableSMC = MetricReading<Double>(
            value: nil, availability: .unavailable, source: .appleSMC, sampledAt: date
        )
        return Self(
            sequence: 0,
            sampledAt: date,
            cpu: CPUMetrics(
                totalPercent: unavailableMach,
                performanceCorePercent: unavailableMach,
                efficiencyCorePercent: unavailableMach,
                logicalCoreCount: ProcessInfo.processInfo.processorCount,
                performanceCoreCount: nil,
                efficiencyCoreCount: nil,
                performanceFrequencyHz: unavailableMach,
                efficiencyFrequencyHz: unavailableMach,
                powerWatts: unavailableMach
            ),
            gpu: GPUMetrics(
                utilizationPercent: unavailableAGX,
                rendererPercent: unavailableAGX,
                tilerPercent: unavailableAGX,
                memoryBytes: MetricReading(value: nil, availability: .unavailable, source: .agxRegistry, sampledAt: date),
                frequencyHz: unavailableAGX,
                powerWatts: unavailableAGX
            ),
            thermal: ThermalMetrics(
                cpuMaxCelsius: unavailableSMC,
                gpuMaxCelsius: unavailableSMC,
                cpuRangeCelsius: nil,
                gpuRangeCelsius: nil,
                systemLevel: .unavailable,
                fans: [],
                hasFanHardware: false,
                socPowerWatts: unavailableSMC
            ),
            memory: MemoryMetrics(
                pressure: .unavailable,
                usedBytes: nil,
                totalBytes: ProcessInfo.processInfo.physicalMemory,
                cachedBytes: nil,
                compressedBytes: nil,
                swapUsedBytes: nil,
                availability: .unavailable,
                sampledAt: date
            ),
            storage: StorageMetrics(
                totalBytes: nil,
                availableForImportantUsageBytes: nil,
                instantaneousReadBytesPerSecond: nil,
                instantaneousWriteBytesPerSecond: nil,
                smoothedReadBytesPerSecond: nil,
                smoothedWriteBytesPerSecond: nil,
                capacityAvailability: .unavailable,
                capacitySampledAt: date,
                diskIOAvailability: .unavailable,
                diskIOSampledAt: date
            ),
            network: NetworkMetrics(
                instantaneousDownBytesPerSecond: nil,
                instantaneousUpBytesPerSecond: nil,
                smoothedDownBytesPerSecond: nil,
                smoothedUpBytesPerSecond: nil,
                availability: .unavailable,
                sampledAt: date
            ),
            capabilities: SystemMonitorCapabilities(
                isAppleSilicon: false,
                chipFamily: nil,
                hasFanHardware: false,
                supportsAGXUtilization: false,
                supportsCPUTemperature: false,
                supportsGPUTemperature: false,
                supportsIOReport: false,
                supportsAppleSMC: false
            )
        )
    }

    func removingDeltaValues(at date: Date) -> Self {
        Self(
            sequence: sequence,
            sampledAt: date,
            cpu: cpu.failed(at: date),
            gpu: gpu,
            thermal: thermal,
            memory: memory,
            storage: storage.clearingRates(at: date, availability: .unavailable),
            network: NetworkMetrics(
                instantaneousDownBytesPerSecond: nil,
                instantaneousUpBytesPerSecond: nil,
                smoothedDownBytesPerSecond: nil,
                smoothedUpBytesPerSecond: nil,
                availability: .unavailable,
                sampledAt: date
            ),
            capabilities: capabilities
        )
    }

    func markingStale(at date: Date, policy: SystemMonitorSamplingPolicy) -> Self {
        let cpuThreshold = threshold(for: .cpu, policy: policy, floor: 5)
        let gpuThreshold = threshold(for: .gpu, policy: policy, floor: 5)
        let thermalThreshold = threshold(for: .temperature, policy: policy, floor: 8)
        return Self(
            sequence: sequence,
            sampledAt: sampledAt,
            cpu: CPUMetrics(
                totalPercent: stale(cpu.totalPercent, at: date, after: cpuThreshold),
                performanceCorePercent: stale(cpu.performanceCorePercent, at: date, after: cpuThreshold),
                efficiencyCorePercent: stale(cpu.efficiencyCorePercent, at: date, after: cpuThreshold),
                logicalCoreCount: cpu.logicalCoreCount,
                performanceCoreCount: cpu.performanceCoreCount,
                efficiencyCoreCount: cpu.efficiencyCoreCount,
                performanceFrequencyHz: cpu.performanceFrequencyHz,
                efficiencyFrequencyHz: cpu.efficiencyFrequencyHz,
                powerWatts: cpu.powerWatts
            ),
            gpu: GPUMetrics(
                utilizationPercent: stale(gpu.utilizationPercent, at: date, after: gpuThreshold),
                rendererPercent: stale(gpu.rendererPercent, at: date, after: gpuThreshold),
                tilerPercent: stale(gpu.tilerPercent, at: date, after: gpuThreshold),
                memoryBytes: gpu.memoryBytes,
                frequencyHz: gpu.frequencyHz,
                powerWatts: gpu.powerWatts
            ),
            thermal: ThermalMetrics(
                cpuMaxCelsius: stale(thermal.cpuMaxCelsius, at: date, after: thermalThreshold),
                gpuMaxCelsius: stale(thermal.gpuMaxCelsius, at: date, after: thermalThreshold),
                cpuRangeCelsius: thermal.cpuRangeCelsius,
                gpuRangeCelsius: thermal.gpuRangeCelsius,
                systemLevel: thermal.systemLevel,
                fans: thermal.fans,
                hasFanHardware: thermal.hasFanHardware,
                fanAvailability: staleFanAvailability(
                    thermal, at: date, after: thermalThreshold
                ),
                fansSampledAt: thermal.fansSampledAt,
                socPowerWatts: thermal.socPowerWatts
            ),
            memory: staleMemory(memory, at: date, policy: policy),
            storage: staleStorage(storage, at: date, policy: policy),
            network: staleNetwork(network, at: date, policy: policy),
            capabilities: capabilities
        )
    }

    private func stale<Value: Codable & Sendable>(
        _ reading: MetricReading<Value>, at date: Date, after threshold: TimeInterval
    ) -> MetricReading<Value> {
        guard reading.availability == .available,
              date.timeIntervalSince(reading.sampledAt) > threshold else { return reading }
        return MetricReading(
            value: nil,
            availability: .stale,
            source: reading.source,
            sampledAt: reading.sampledAt
        )
    }

    private func threshold(
        for domain: SamplingDomain,
        policy: SystemMonitorSamplingPolicy,
        floor: TimeInterval
    ) -> TimeInterval {
        guard let interval = policy.interval(for: domain) else { return floor }
        let components = interval.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return max(floor, seconds * 3)
    }

    private func staleFanAvailability(
        _ thermal: ThermalMetrics,
        at date: Date,
        after threshold: TimeInterval
    ) -> MetricAvailability {
        guard thermal.fanAvailability == .available,
              let sampledAt = thermal.fansSampledAt,
              date.timeIntervalSince(sampledAt) > threshold else {
            return thermal.fanAvailability
        }
        return .stale
    }

    private func staleMemory(
        _ memory: MemoryMetrics,
        at date: Date,
        policy: SystemMonitorSamplingPolicy
    ) -> MemoryMetrics {
        let limit = threshold(for: .memory, policy: policy, floor: 5)
        guard memory.availability == .available,
              date.timeIntervalSince(memory.sampledAt) > limit else { return memory }
        return MemoryMetrics(
            pressure: memory.pressure,
            usedBytes: nil,
            totalBytes: memory.totalBytes,
            cachedBytes: nil,
            compressedBytes: nil,
            swapUsedBytes: nil,
            availability: .stale,
            sampledAt: memory.sampledAt
        )
    }

    private func staleStorage(
        _ storage: StorageMetrics,
        at date: Date,
        policy: SystemMonitorSamplingPolicy
    ) -> StorageMetrics {
        let diskLimit = threshold(for: .diskIO, policy: policy, floor: 5)
        let capacityStale = storage.capacityAvailability == .available
            && date.timeIntervalSince(storage.capacitySampledAt) > 180
        let diskStale = storage.diskIOAvailability == .available
            && date.timeIntervalSince(storage.diskIOSampledAt) > diskLimit
        return StorageMetrics(
            totalBytes: capacityStale ? nil : storage.totalBytes,
            availableForImportantUsageBytes: capacityStale
                ? nil : storage.availableForImportantUsageBytes,
            instantaneousReadBytesPerSecond: diskStale
                ? nil : storage.instantaneousReadBytesPerSecond,
            instantaneousWriteBytesPerSecond: diskStale
                ? nil : storage.instantaneousWriteBytesPerSecond,
            smoothedReadBytesPerSecond: diskStale
                ? nil : storage.smoothedReadBytesPerSecond,
            smoothedWriteBytesPerSecond: diskStale
                ? nil : storage.smoothedWriteBytesPerSecond,
            capacityAvailability: capacityStale ? .stale : storage.capacityAvailability,
            capacitySampledAt: storage.capacitySampledAt,
            diskIOAvailability: diskStale ? .stale : storage.diskIOAvailability,
            diskIOSampledAt: storage.diskIOSampledAt
        )
    }

    private func staleNetwork(
        _ network: NetworkMetrics,
        at date: Date,
        policy: SystemMonitorSamplingPolicy
    ) -> NetworkMetrics {
        let limit = threshold(for: .network, policy: policy, floor: 5)
        guard network.availability == .available,
              date.timeIntervalSince(network.sampledAt) > limit else { return network }
        return NetworkMetrics(
            instantaneousDownBytesPerSecond: nil,
            instantaneousUpBytesPerSecond: nil,
            smoothedDownBytesPerSecond: nil,
            smoothedUpBytesPerSecond: nil,
            availability: .stale,
            sampledAt: network.sampledAt
        )
    }
}

private extension CPUMetrics {
    func failed(at date: Date) -> Self {
        let failed = MetricReading<Double>(value: nil, availability: .failed, source: .mach, sampledAt: date)
        return Self(
            totalPercent: failed,
            performanceCorePercent: failed,
            efficiencyCorePercent: failed,
            logicalCoreCount: logicalCoreCount,
            performanceCoreCount: performanceCoreCount,
            efficiencyCoreCount: efficiencyCoreCount,
            performanceFrequencyHz: performanceFrequencyHz,
            efficiencyFrequencyHz: efficiencyFrequencyHz,
            powerWatts: powerWatts
        )
    }
}

private extension GPUMetrics {
    init(payload: GPUMetricsPayload?, diagnostics: [MetricDiagnosticPayload], at date: Date) {
        let source = payload?.source ?? .agxRegistry
        utilizationPercent = Self.reading(payload?.utilizationPercent, "gpu", source, diagnostics, date)
        rendererPercent = Self.reading(payload?.rendererPercent, "gpuRenderer", source, diagnostics, date)
        tilerPercent = Self.reading(payload?.tilerPercent, "gpuTiler", source, diagnostics, date)
        memoryBytes = MetricReading(
            value: payload?.memoryBytes,
            availability: payload?.memoryBytes == nil ? .unavailable : .available,
            source: source,
            sampledAt: date
        )
        frequencyHz = Self.reading(payload?.frequencyHz, "frequencyAndPower", source, diagnostics, date)
        powerWatts = Self.reading(payload?.powerWatts, "frequencyAndPower", source, diagnostics, date)
    }

    func failed(at date: Date) -> Self {
        let failed = MetricReading<Double>(value: nil, availability: .failed, source: .agxRegistry, sampledAt: date)
        return Self(
            utilizationPercent: failed,
            rendererPercent: failed,
            tilerPercent: failed,
            memoryBytes: MetricReading(value: nil, availability: .failed, source: .agxRegistry, sampledAt: date),
            frequencyHz: frequencyHz,
            powerWatts: powerWatts
        )
    }

    private static func reading(
        _ value: Double?, _ domain: String, _ source: MonitorSource,
        _ diagnostics: [MetricDiagnosticPayload], _ date: Date
    ) -> MetricReading<Double> {
        let availability: MetricAvailability
        if value != nil {
            availability = .available
        } else if diagnostics.contains(where: { $0.domain == domain && $0.status == "unsupported" }) {
            availability = .unavailable
        } else {
            availability = .failed
        }
        return MetricReading(value: value, availability: availability, source: source, sampledAt: date)
    }
}

private extension ThermalMetrics {
    func withSystemLevel(_ level: SystemThermalLevel) -> Self {
        return Self(
            cpuMaxCelsius: cpuMaxCelsius, gpuMaxCelsius: gpuMaxCelsius,
            cpuRangeCelsius: cpuRangeCelsius, gpuRangeCelsius: gpuRangeCelsius,
            systemLevel: level, fans: fans, hasFanHardware: hasFanHardware,
            fanAvailability: fanAvailability, fansSampledAt: fansSampledAt,
            socPowerWatts: socPowerWatts
        )
    }

    func mergingTemperatures(
        _ payload: TemperatureMetricsPayload?, diagnostics: [MetricDiagnosticPayload], at date: Date
    ) -> Self {
        let source = payload?.source ?? .appleSMC
        let cpu = temperatureReading(payload?.cpuMaxCelsius, "cpuTemperature", source, diagnostics, date)
        let gpu = temperatureReading(payload?.gpuMaxCelsius, "gpuTemperature", source, diagnostics, date)
        return Self(
            cpuMaxCelsius: cpu,
            gpuMaxCelsius: gpu,
            cpuRangeCelsius: range(payload?.cpuMinimumCelsius, payload?.cpuMaxCelsius),
            gpuRangeCelsius: range(payload?.gpuMinimumCelsius, payload?.gpuMaxCelsius),
            systemLevel: systemLevel,
            fans: fans,
            hasFanHardware: hasFanHardware,
            fanAvailability: fanAvailability,
            fansSampledAt: fansSampledAt,
            socPowerWatts: MetricReading(
                value: payload?.socPowerWatts,
                availability: payload?.socPowerWatts == nil ? .unavailable : .available,
                source: source,
                sampledAt: date
            )
        )
    }

    func mergingFans(
        _ values: [FanMetrics],
        diagnostics: [MetricDiagnosticPayload],
        capabilities: SystemMonitorCapabilities,
        at date: Date
    ) -> Self {
        let availability: MetricAvailability
        if !capabilities.hasFanHardware {
            availability = .unavailable
        } else if diagnostics.contains(where: {
            $0.domain == "fans" && $0.status == "available"
        }) {
            availability = .available
        } else {
            availability = .failed
        }
        return Self(
            cpuMaxCelsius: cpuMaxCelsius, gpuMaxCelsius: gpuMaxCelsius,
            cpuRangeCelsius: cpuRangeCelsius, gpuRangeCelsius: gpuRangeCelsius,
            systemLevel: systemLevel,
            fans: values,
            hasFanHardware: capabilities.hasFanHardware,
            fanAvailability: availability,
            fansSampledAt: date,
            socPowerWatts: socPowerWatts
        )
    }

    func failedTemperatures(at date: Date) -> Self {
        let failed = MetricReading<Double>(value: nil, availability: .failed, source: .appleSMC, sampledAt: date)
        return Self(
            cpuMaxCelsius: failed, gpuMaxCelsius: failed,
            cpuRangeCelsius: nil, gpuRangeCelsius: nil,
            systemLevel: systemLevel, fans: fans, hasFanHardware: hasFanHardware,
            fanAvailability: fanAvailability, fansSampledAt: fansSampledAt,
            socPowerWatts: socPowerWatts
        )
    }

    func clearingFailedFans(at date: Date = Date()) -> Self {
        Self(
            cpuMaxCelsius: cpuMaxCelsius, gpuMaxCelsius: gpuMaxCelsius,
            cpuRangeCelsius: cpuRangeCelsius, gpuRangeCelsius: gpuRangeCelsius,
            systemLevel: systemLevel, fans: [], hasFanHardware: hasFanHardware,
            fanAvailability: hasFanHardware ? .failed : .unavailable,
            fansSampledAt: date,
            socPowerWatts: socPowerWatts
        )
    }

    private func temperatureReading(
        _ value: Double?, _ domain: String, _ source: MonitorSource,
        _ diagnostics: [MetricDiagnosticPayload], _ date: Date
    ) -> MetricReading<Double> {
        let availability: MetricAvailability
        if value != nil {
            availability = .available
        } else if diagnostics.contains(where: { $0.domain == domain && $0.status == "unsupported" }) {
            availability = .unavailable
        } else {
            availability = .failed
        }
        return MetricReading(value: value, availability: availability, source: source, sampledAt: date)
    }

    private func range(_ minimum: Double?, _ maximum: Double?) -> ClosedRange<Double>? {
        guard let minimum, let maximum, minimum <= maximum else { return nil }
        return minimum...maximum
    }
}

private extension StorageMetrics {
    func mergingCapacity(_ value: Self) -> Self {
        Self(
            totalBytes: value.totalBytes,
            availableForImportantUsageBytes: value.availableForImportantUsageBytes,
            instantaneousReadBytesPerSecond: instantaneousReadBytesPerSecond,
            instantaneousWriteBytesPerSecond: instantaneousWriteBytesPerSecond,
            smoothedReadBytesPerSecond: smoothedReadBytesPerSecond,
            smoothedWriteBytesPerSecond: smoothedWriteBytesPerSecond,
            capacityAvailability: value.capacityAvailability,
            capacitySampledAt: value.capacitySampledAt,
            diskIOAvailability: diskIOAvailability,
            diskIOSampledAt: diskIOSampledAt
        )
    }

    func mergingRates(_ value: Self) -> Self {
        Self(
            totalBytes: totalBytes,
            availableForImportantUsageBytes: availableForImportantUsageBytes,
            instantaneousReadBytesPerSecond: value.instantaneousReadBytesPerSecond,
            instantaneousWriteBytesPerSecond: value.instantaneousWriteBytesPerSecond,
            smoothedReadBytesPerSecond: value.smoothedReadBytesPerSecond,
            smoothedWriteBytesPerSecond: value.smoothedWriteBytesPerSecond,
            capacityAvailability: capacityAvailability,
            capacitySampledAt: capacitySampledAt,
            diskIOAvailability: value.diskIOAvailability,
            diskIOSampledAt: value.diskIOSampledAt
        )
    }

    func clearingCapacity(at date: Date = Date()) -> Self {
        mergingCapacity(Self(
            totalBytes: nil,
            availableForImportantUsageBytes: nil,
            instantaneousReadBytesPerSecond: nil,
            instantaneousWriteBytesPerSecond: nil,
            smoothedReadBytesPerSecond: nil,
            smoothedWriteBytesPerSecond: nil,
            capacityAvailability: .failed,
            capacitySampledAt: date
        ))
    }

    func clearingRates(
        at date: Date = Date(),
        availability: MetricAvailability = .failed
    ) -> Self {
        mergingRates(Self(
            totalBytes: nil,
            availableForImportantUsageBytes: nil,
            instantaneousReadBytesPerSecond: nil,
            instantaneousWriteBytesPerSecond: nil,
            smoothedReadBytesPerSecond: nil,
            smoothedWriteBytesPerSecond: nil,
            diskIOAvailability: availability,
            diskIOSampledAt: date
        ))
    }
}

private extension SystemMonitorCapabilitiesPayload {
    var model: SystemMonitorCapabilities {
        SystemMonitorCapabilities(
            isAppleSilicon: isAppleSilicon,
            chipFamily: chipFamily,
            hasFanHardware: hasFanHardware,
            supportsAGXUtilization: supportsAGXUtilization,
            supportsCPUTemperature: supportsCPUTemperature,
            supportsGPUTemperature: supportsGPUTemperature,
            supportsIOReport: supportsIOReport,
            supportsAppleSMC: supportsAppleSMC
        )
    }
}
