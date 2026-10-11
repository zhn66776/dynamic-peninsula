import XCTest
@testable import Dynamic_Peninsula

final class SamplerStoreAndAlertTests: XCTestCase {
    func testOneInFlightSkipsRatherThanQueues() async {
        let base = ContinuousClock.now
        let publicProvider = ControlledPublicProvider(blockFirst: true)
        let sampler = SystemMonitorSampler(
            publicProvider: publicProvider,
            privateProvider: FixturePrivateProvider(),
            clock: FixedMonitorClock(now: base),
            currentDate: { Date(timeIntervalSince1970: 100) }
        )
        await sampler.setContext(.foreground)

        let first = Task { await sampler.sampleIfDue(at: base) }
        while !(await publicProvider.hasStarted) { await Task.yield() }
        await sampler.sampleIfDue(at: base.advanced(by: .seconds(10)))
        var statistics = await sampler.currentStatistics()
        XCTAssertEqual(statistics.skippedSamples, 1)
        XCTAssertEqual(statistics.completedSamples, 0)

        await publicProvider.release()
        await first.value
        statistics = await sampler.currentStatistics()
        XCTAssertEqual(statistics.completedSamples, 1)
        let callCount = await publicProvider.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testSnapshotStreamBuffersNewestOnly() async {
        let base = ContinuousClock.now
        let sampler = SystemMonitorSampler(
            publicProvider: ControlledPublicProvider(blockFirst: false),
            privateProvider: FixturePrivateProvider(),
            clock: FixedMonitorClock(now: base),
            currentDate: { Date(timeIntervalSince1970: 200) }
        )
        let stream = await sampler.snapshots()
        await sampler.setContext(.foreground)
        await sampler.sampleIfDue(at: base)
        await sampler.sampleIfDue(at: base.advanced(by: .seconds(2)))
        await sampler.sampleIfDue(at: base.advanced(by: .seconds(4)))

        var iterator = stream.makeAsyncIterator()
        let newest = await iterator.next()
        XCTAssertEqual(newest?.sequence, 3)
        await sampler.stop()
    }

    func testTransientFirstPrivateFailureRetriesAndRecovers() async {
        let base = ContinuousClock.now
        let sampler = SystemMonitorSampler(
            publicProvider: ControlledPublicProvider(blockFirst: false),
            privateProvider: FlakyPrivateProvider(),
            clock: FixedMonitorClock(now: base),
            currentDate: { Date(timeIntervalSince1970: 1) }
        )
        let stream = await sampler.snapshots()
        await sampler.setContext(.foreground)
        await sampler.sampleIfDue(at: base)
        await sampler.sampleIfDue(at: base.advanced(by: .seconds(2)))

        var iterator = stream.makeAsyncIterator()
        let recovered = await iterator.next()
        XCTAssertEqual(recovered?.sequence, 2)
        XCTAssertEqual(recovered?.gpu.utilizationPercent.availability, .available)
        let statistics = await sampler.currentStatistics()
        XCTAssertEqual(statistics.privateRequests, 2)
        await sampler.stop()
    }

    func testWakeClearsExplicitUnsupportedCapabilityAndReprobes() async {
        let base = ContinuousClock.now
        let privateProvider = UnsupportedThenWakePrivateProvider()
        let sampler = SystemMonitorSampler(
            publicProvider: ControlledPublicProvider(blockFirst: false),
            privateProvider: privateProvider,
            clock: FixedMonitorClock(now: base)
        )
        await sampler.setContext(.foreground)
        await sampler.sampleIfDue(at: base)
        await sampler.sampleIfDue(at: base.advanced(by: .seconds(2)))
        let callsBeforeWake = await privateProvider.callCount
        XCTAssertEqual(callsBeforeWake, 1)

        await sampler.handleWake()
        await sampler.sampleIfDue(at: base.advanced(by: .seconds(3)))
        let callsAfterWake = await privateProvider.callCount
        let resetCount = await privateProvider.resetCount
        XCTAssertEqual(callsAfterWake, 2)
        XCTAssertEqual(resetCount, 1)
    }

    func testMemoryStorageDiskAndFansBecomeStaleAtTheirOwnThresholds() {
        let old = Date(timeIntervalSince1970: 1)
        let now = Date(timeIntervalSince1970: 200)
        let base = SystemMonitorSnapshot.placeholder(at: old)
        let snapshot = SystemMonitorSnapshot(
            sequence: 1,
            sampledAt: old,
            cpu: base.cpu,
            gpu: base.gpu,
            thermal: ThermalMetrics(
                cpuMaxCelsius: base.thermal.cpuMaxCelsius,
                gpuMaxCelsius: base.thermal.gpuMaxCelsius,
                cpuRangeCelsius: nil,
                gpuRangeCelsius: nil,
                systemLevel: .nominal,
                fans: [FanMetrics(id: 0, name: "Fan 1", rpm: 0)],
                hasFanHardware: true,
                fanAvailability: .available,
                fansSampledAt: old,
                socPowerWatts: base.thermal.socPowerWatts
            ),
            memory: MemoryMetrics(
                pressure: .normal,
                usedBytes: 8,
                totalBytes: 16,
                cachedBytes: 2,
                compressedBytes: 1,
                swapUsedBytes: 0,
                availability: .available,
                sampledAt: old
            ),
            storage: StorageMetrics(
                totalBytes: 100,
                availableForImportantUsageBytes: 50,
                instantaneousReadBytesPerSecond: 3,
                instantaneousWriteBytesPerSecond: 4,
                smoothedReadBytesPerSecond: 2,
                smoothedWriteBytesPerSecond: 3,
                capacityAvailability: .available,
                capacitySampledAt: old,
                diskIOAvailability: .available,
                diskIOSampledAt: old
            ),
            network: base.network,
            capabilities: base.capabilities
        )
        let stale = snapshot.markingStale(
            at: now,
            policy: SystemMonitorSamplingPolicy(
                context: .foreground, isLowPowerMode: false, backoffLevel: 0
            )
        )
        XCTAssertEqual(stale.memory.availability, .stale)
        XCTAssertNil(stale.memory.usedBytes)
        XCTAssertEqual(stale.storage.capacityAvailability, .stale)
        XCTAssertNil(stale.storage.totalBytes)
        XCTAssertEqual(stale.storage.diskIOAvailability, .stale)
        XCTAssertNil(stale.storage.smoothedWriteBytesPerSecond)
        XCTAssertEqual(stale.thermal.fanAvailability, .stale)
    }

    func testFanfulReadFailurePreservesFailedAvailability() async {
        let base = ContinuousClock.now
        let sampler = SystemMonitorSampler(
            publicProvider: ControlledPublicProvider(blockFirst: false),
            privateProvider: FanFailurePrivateProvider(),
            clock: FixedMonitorClock(now: base)
        )
        let stream = await sampler.snapshots()
        await sampler.setContext(.foreground)
        await sampler.sampleIfDue(at: base)
        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        XCTAssertTrue(value?.thermal.hasFanHardware == true)
        XCTAssertEqual(value?.thermal.fanAvailability, .failed)
        XCTAssertEqual(value?.thermal.fans, [])
        await sampler.stop()
    }

    func testFailedMemoryPressureFallbackIsConsumedUntilWake() async {
        let base = ContinuousClock.now
        let privateProvider = FailedMemoryPressureProvider()
        let sampler = SystemMonitorSampler(
            publicProvider: ControlledPublicProvider(blockFirst: false),
            privateProvider: privateProvider,
            clock: FixedMonitorClock(now: base)
        )
        await sampler.setContext(.foreground)
        await sampler.sampleIfDue(at: base)
        await sampler.sampleIfDue(at: base.advanced(by: .seconds(2)))
        let callCount = await privateProvider.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testWakeResetsPublicBaselineAndPrivateCapabilities() async {
        let base = ContinuousClock.now
        let publicProvider = ControlledPublicProvider(blockFirst: false)
        let privateProvider = FixturePrivateProvider()
        let sampler = SystemMonitorSampler(
            publicProvider: publicProvider,
            privateProvider: privateProvider,
            clock: FixedMonitorClock(now: base)
        )
        await sampler.setContext(.background)
        await sampler.handleWake()
        await sampler.sampleIfDue(at: base)
        let publicResetCount = await publicProvider.resetCount
        let privateResetCount = await privateProvider.resetCount
        let sampleCount = await publicProvider.callCount
        XCTAssertEqual(publicResetCount, 1)
        XCTAssertEqual(privateResetCount, 1)
        XCTAssertEqual(sampleCount, 1)
    }

    func testSuspendedAndDisabledContextsDoNotSample() async {
        let base = ContinuousClock.now
        let publicProvider = ControlledPublicProvider(blockFirst: false)
        let sampler = SystemMonitorSampler(
            publicProvider: publicProvider,
            privateProvider: FixturePrivateProvider(),
            clock: FixedMonitorClock(now: base)
        )
        await sampler.setContext(.suspended)
        await sampler.sampleIfDue(at: base.advanced(by: .seconds(120)))
        await sampler.setContext(.disabled)
        await sampler.sampleIfDue(at: base.advanced(by: .seconds(240)))
        let callCount = await publicProvider.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testMemoryCriticalTransitionCooldownAndRecovery() {
        var controller = SystemMonitorAlertController()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(controller.evaluate(
            snapshot: snapshot(memory: .normal), at: start, enabled: true, interactionBusy: false
        ))
        XCTAssertNil(controller.evaluate(
            snapshot: snapshot(memory: .warning), at: start.addingTimeInterval(1),
            enabled: true, interactionBusy: false
        ))
        XCTAssertNil(controller.evaluate(
            snapshot: snapshot(memory: .warning), at: start.addingTimeInterval(2),
            enabled: true, interactionBusy: false
        ))
        XCTAssertEqual(controller.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(3),
            enabled: true, interactionBusy: false
        )?.kind, .memoryCritical)
        _ = controller.evaluate(
            snapshot: snapshot(memory: .normal), at: start.addingTimeInterval(4),
            enabled: true, interactionBusy: false
        )
        XCTAssertNil(controller.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(5),
            enabled: true, interactionBusy: false
        ))
        _ = controller.evaluate(
            snapshot: snapshot(memory: .normal), at: start.addingTimeInterval(601),
            enabled: true, interactionBusy: false
        )
        XCTAssertEqual(controller.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(604),
            enabled: true, interactionBusy: false
        )?.kind, .memoryCritical)
    }

    func testAlertDefersDuringInteractionAndDropsExpiredPending() {
        var controller = SystemMonitorAlertController()
        let start = Date(timeIntervalSince1970: 2_000)
        _ = controller.evaluate(
            snapshot: snapshot(memory: .normal), at: start, enabled: true, interactionBusy: false
        )
        XCTAssertNil(controller.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(1),
            enabled: true, interactionBusy: true
        ))
        XCTAssertEqual(controller.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(20),
            enabled: true, interactionBusy: false
        )?.kind, .memoryCritical)

        var expired = SystemMonitorAlertController()
        _ = expired.evaluate(snapshot: snapshot(memory: .normal), at: start, enabled: true, interactionBusy: false)
        _ = expired.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(1),
            enabled: true, interactionBusy: true
        )
        XCTAssertNil(expired.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(32),
            enabled: true, interactionBusy: false
        ))
    }

    func testDisabledAlertsUpdateBaselineWithoutSurpriseOnEnable() {
        var controller = SystemMonitorAlertController()
        let start = Date(timeIntervalSince1970: 3_000)
        XCTAssertNil(controller.evaluate(
            snapshot: snapshot(memory: .critical), at: start,
            enabled: false, interactionBusy: false
        ))
        XCTAssertNil(controller.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(1),
            enabled: true, interactionBusy: false
        ))
        XCTAssertNil(controller.evaluate(
            snapshot: snapshot(memory: .normal), at: start.addingTimeInterval(2),
            enabled: true, interactionBusy: false
        ))
        XCTAssertEqual(controller.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(3),
            enabled: true, interactionBusy: false
        )?.kind, .memoryCritical)
    }

    func testUnavailableDoesNotRearmAnExistingCriticalAlert() {
        var controller = SystemMonitorAlertController()
        let start = Date(timeIntervalSince1970: 4_000)
        _ = controller.evaluate(
            snapshot: snapshot(memory: .normal), at: start,
            enabled: true, interactionBusy: false
        )
        XCTAssertEqual(controller.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(1),
            enabled: true, interactionBusy: false
        )?.kind, .memoryCritical)
        XCTAssertNil(controller.evaluate(
            snapshot: snapshot(memory: .unavailable), at: start.addingTimeInterval(2),
            enabled: true, interactionBusy: false
        ))
        XCTAssertNil(controller.evaluate(
            snapshot: snapshot(memory: .critical), at: start.addingTimeInterval(3),
            enabled: true, interactionBusy: false
        ))
    }

    private func snapshot(memory pressure: MemoryPressureLevel) -> SystemMonitorSnapshot {
        let base = SystemMonitorSnapshot.placeholder(at: Date(timeIntervalSince1970: 1))
        return SystemMonitorSnapshot(
            sequence: 1,
            sampledAt: base.sampledAt,
            cpu: base.cpu,
            gpu: base.gpu,
            thermal: ThermalMetrics(
                cpuMaxCelsius: base.thermal.cpuMaxCelsius,
                gpuMaxCelsius: base.thermal.gpuMaxCelsius,
                cpuRangeCelsius: nil,
                gpuRangeCelsius: nil,
                systemLevel: .nominal,
                fans: [],
                hasFanHardware: false,
                socPowerWatts: base.thermal.socPowerWatts
            ),
            memory: MemoryMetrics(
                pressure: pressure,
                usedBytes: 8 * 1_073_741_824,
                totalBytes: 16 * 1_073_741_824,
                cachedBytes: 2 * 1_073_741_824,
                compressedBytes: 1_073_741_824,
                swapUsedBytes: 0
            ),
            storage: StorageMetrics(
                totalBytes: 500 * 1_073_741_824,
                availableForImportantUsageBytes: 100 * 1_073_741_824,
                instantaneousReadBytesPerSecond: 0,
                instantaneousWriteBytesPerSecond: 0,
                smoothedReadBytesPerSecond: 0,
                smoothedWriteBytesPerSecond: 0
            ),
            network: base.network,
            capabilities: base.capabilities
        )
    }
}

private struct FixedMonitorClock: SystemMonitorClock {
    let now: ContinuousClock.Instant
    func sleep(until deadline: ContinuousClock.Instant) async throws { throw CancellationError() }
}

private actor ControlledPublicProvider: SystemPublicMetricsProviding {
    private let blockFirst: Bool
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false
    private(set) var callCount = 0
    private(set) var resetCount = 0

    init(blockFirst: Bool) { self.blockFirst = blockFirst }

    func sample(
        domains: PublicMetricDomains,
        at instant: ContinuousClock.Instant
    ) async -> PublicMetricsPartialSnapshot {
        callCount += 1
        hasStarted = true
        if blockFirst && callCount == 1 {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        let date = Date(timeIntervalSince1970: Double(callCount))
        let available = MetricReading(value: Double(callCount), availability: .available, source: .mach, sampledAt: date)
        let unavailable = MetricReading<Double>(value: nil, availability: .unavailable, source: .mach, sampledAt: date)
        let cpu = CPUMetrics(
            totalPercent: available,
            performanceCorePercent: available,
            efficiencyCorePercent: available,
            logicalCoreCount: 8,
            performanceCoreCount: 4,
            efficiencyCoreCount: 4,
            performanceFrequencyHz: unavailable,
            efficiencyFrequencyHz: unavailable,
            powerWatts: unavailable
        )
        return PublicMetricsPartialSnapshot(
            sampledAt: date,
            cpu: domains.contains(.cpu) ? .success(cpu) : nil,
            memory: nil,
            capacity: nil,
            diskIO: nil,
            thermal: domains.contains(.thermal) ? .success(.nominal) : nil,
            network: nil
        )
    }

    func resetDeltaBaselines() async { resetCount += 1 }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor FlakyPrivateProvider: SystemPrivateMetricsProviding {
    private var calls = 0
    private let fixture = FixturePrivateProvider()

    func sample(domains: PrivateMetricDomains) async throws -> SystemMonitorXPCSnapshot {
        calls += 1
        if calls == 1 { throw SystemMonitorXPCError.transportInterrupted }
        return try await fixture.sample(domains: domains)
    }

    func resetCapabilities() async {}
}

private actor UnsupportedThenWakePrivateProvider: SystemPrivateMetricsProviding {
    private(set) var callCount = 0
    private(set) var resetCount = 0
    private var didReset = false
    private let fixture = FixturePrivateProvider()

    func sample(domains: PrivateMetricDomains) async throws -> SystemMonitorXPCSnapshot {
        callCount += 1
        if didReset { return try await fixture.sample(domains: domains) }
        return SystemMonitorXPCSnapshot(
            schemaVersion: 1,
            sampledAt: Date(timeIntervalSince1970: 1),
            capabilities: SystemMonitorCapabilitiesPayload(
                isAppleSilicon: true,
                chipFamily: "M3",
                hasFanHardware: false,
                supportsAGXUtilization: false,
                supportsCPUTemperature: false,
                supportsGPUTemperature: false,
                supportsIOReport: false,
                supportsAppleSMC: false
            ),
            gpu: nil,
            temperatures: nil,
            fans: [],
            diagnostics: [
                MetricDiagnosticPayload(domain: "gpu", status: "unsupported", reason: "fixture"),
                MetricDiagnosticPayload(domain: "cpuTemperature", status: "unsupported", reason: "fixture"),
                MetricDiagnosticPayload(domain: "gpuTemperature", status: "unsupported", reason: "fixture"),
                MetricDiagnosticPayload(domain: "fans", status: "unsupported", reason: "noFanHardware"),
                MetricDiagnosticPayload(domain: "memoryPressure", status: "unsupported", reason: "fixture")
            ]
        )
    }

    func resetCapabilities() async {
        resetCount += 1
        didReset = true
    }
}

private actor FanFailurePrivateProvider: SystemPrivateMetricsProviding {
    func sample(domains: PrivateMetricDomains) async throws -> SystemMonitorXPCSnapshot {
        SystemMonitorXPCSnapshot(
            schemaVersion: 1,
            sampledAt: Date(timeIntervalSince1970: 1),
            capabilities: SystemMonitorCapabilitiesPayload(
                isAppleSilicon: true,
                chipFamily: "M3",
                hasFanHardware: true,
                supportsAGXUtilization: false,
                supportsCPUTemperature: false,
                supportsGPUTemperature: false,
                supportsIOReport: false,
                supportsAppleSMC: true
            ),
            gpu: nil,
            temperatures: nil,
            fans: [],
            diagnostics: [
                MetricDiagnosticPayload(domain: "gpu", status: "failed", reason: "fixture"),
                MetricDiagnosticPayload(domain: "cpuTemperature", status: "failed", reason: "fixture"),
                MetricDiagnosticPayload(domain: "gpuTemperature", status: "failed", reason: "fixture"),
                MetricDiagnosticPayload(domain: "fans", status: "failed", reason: "fanReadFailed")
            ]
        )
    }

    func resetCapabilities() async {}
}

private actor FailedMemoryPressureProvider: SystemPrivateMetricsProviding {
    private(set) var callCount = 0

    func sample(domains: PrivateMetricDomains) async throws -> SystemMonitorXPCSnapshot {
        callCount += 1
        return SystemMonitorXPCSnapshot(
            schemaVersion: 1,
            sampledAt: Date(timeIntervalSince1970: 1),
            capabilities: SystemMonitorCapabilitiesPayload(
                isAppleSilicon: true,
                chipFamily: "M3",
                hasFanHardware: false,
                supportsAGXUtilization: false,
                supportsCPUTemperature: false,
                supportsGPUTemperature: false,
                supportsIOReport: false,
                supportsAppleSMC: false
            ),
            gpu: nil,
            temperatures: nil,
            fans: [],
            diagnostics: [
                MetricDiagnosticPayload(domain: "gpu", status: "unsupported", reason: "fixture"),
                MetricDiagnosticPayload(domain: "cpuTemperature", status: "unsupported", reason: "fixture"),
                MetricDiagnosticPayload(domain: "gpuTemperature", status: "unsupported", reason: "fixture"),
                MetricDiagnosticPayload(domain: "fans", status: "unsupported", reason: "fixture"),
                MetricDiagnosticPayload(domain: "memoryPressure", status: "failed", reason: "fixture")
            ]
        )
    }

    func resetCapabilities() async {}
}

private actor FixturePrivateProvider: SystemPrivateMetricsProviding {
    private(set) var resetCount = 0

    func sample(domains: PrivateMetricDomains) async throws -> SystemMonitorXPCSnapshot {
        SystemMonitorXPCSnapshot(
            schemaVersion: 1,
            sampledAt: Date(timeIntervalSince1970: 1),
            capabilities: SystemMonitorCapabilitiesPayload(
                isAppleSilicon: true,
                chipFamily: "M3",
                hasFanHardware: true,
                supportsAGXUtilization: true,
                supportsCPUTemperature: true,
                supportsGPUTemperature: true,
                supportsIOReport: true,
                supportsAppleSMC: true
            ),
            gpu: domains.contains(.gpu) ? GPUMetricsPayload(
                utilizationPercent: 20,
                rendererPercent: 18,
                tilerPercent: 19,
                memoryBytes: nil,
                frequencyHz: nil,
                powerWatts: nil,
                source: .agxRegistry
            ) : nil,
            temperatures: domains.contains(.temperatures) ? TemperatureMetricsPayload(
                cpuMaxCelsius: 55,
                gpuMaxCelsius: 50,
                cpuMinimumCelsius: 45,
                gpuMinimumCelsius: 42,
                socPowerWatts: nil,
                source: .appleSMC
            ) : nil,
            fans: domains.contains(.fans) ? [FanMetrics(id: 0, name: "Fan 1", rpm: 0)] : [],
            diagnostics: [
                MetricDiagnosticPayload(domain: "gpu", status: "available", reason: nil),
                MetricDiagnosticPayload(domain: "gpuRenderer", status: "available", reason: nil),
                MetricDiagnosticPayload(domain: "gpuTiler", status: "available", reason: nil),
                MetricDiagnosticPayload(domain: "cpuTemperature", status: "available", reason: nil),
                MetricDiagnosticPayload(domain: "gpuTemperature", status: "available", reason: nil)
            ]
        )
    }

    func resetCapabilities() async { resetCount += 1 }
}
