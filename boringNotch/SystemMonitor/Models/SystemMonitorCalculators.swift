import Foundation

struct CPUCoreTicks: Equatable, Sendable {
    let user: UInt32
    let system: UInt32
    let nice: UInt32
    let idle: UInt32
}

struct CPUCoreGrouping: Equatable, Sendable {
    let performanceIndices: [Int]
    let efficiencyIndices: [Int]

    var isComplete: Bool {
        let all = performanceIndices + efficiencyIndices
        return !performanceIndices.isEmpty
            && !efficiencyIndices.isEmpty
            && Set(all).count == all.count
    }

    func isValid(forCoreCount coreCount: Int) -> Bool {
        isComplete && Set(performanceIndices + efficiencyIndices) == Set(0..<coreCount)
    }
}

struct CPUDeltaResult: Equatable, Sendable {
    let totalPercent: Double
    let performancePercent: Double?
    let efficiencyPercent: Double?
}

enum CPUDeltaCalculator {
    static func calculate(
        previous: [CPUCoreTicks]?,
        current: [CPUCoreTicks],
        grouping: CPUCoreGrouping?
    ) -> Result<CPUDeltaResult, SystemMetricsProviderError>? {
        guard let previous else { return nil }
        guard previous.count == current.count, !current.isEmpty else {
            return .failure(.malformedValue(domain: "cpu", field: "coreCount"))
        }

        var deltas: [(busy: UInt64, total: UInt64)] = []
        deltas.reserveCapacity(current.count)
        for (old, new) in zip(previous, current) {
            guard let user = tickDelta(previous: old.user, current: new.user),
                  let system = tickDelta(previous: old.system, current: new.system),
                  let nice = tickDelta(previous: old.nice, current: new.nice),
                  let idle = tickDelta(previous: old.idle, current: new.idle) else {
                return nil
            }
            let busy = user + system + nice
            let total = busy + idle
            deltas.append((busy, total))
        }

        guard deltas.contains(where: { $0.total > 0 }) else { return nil }
        guard let totalPercent = percentage(for: deltas.indices, deltas: deltas) else {
            return .failure(.malformedValue(domain: "cpu", field: "totalPercent"))
        }

        var performancePercent: Double?
        var efficiencyPercent: Double?
        if let grouping, grouping.isValid(forCoreCount: deltas.count) {
            performancePercent = percentage(for: grouping.performanceIndices, deltas: deltas)
            efficiencyPercent = percentage(for: grouping.efficiencyIndices, deltas: deltas)
        }

        return .success(
            CPUDeltaResult(
                totalPercent: totalPercent,
                performancePercent: performancePercent,
                efficiencyPercent: efficiencyPercent
            )
        )
    }

    private static func tickDelta(previous: UInt32, current: UInt32) -> UInt64? {
        if current >= previous {
            return UInt64(current - previous)
        }

        // A real UInt32 wrap crosses the ends of the counter range. A smaller
        // backwards jump is treated as a reset/sleep baseline and discarded.
        let highBoundary = UInt32.max - UInt32.max / 4
        let lowBoundary = UInt32.max / 4
        guard previous >= highBoundary, current <= lowBoundary else { return nil }
        return UInt64(current &- previous)
    }

    private static func percentage<C: Collection>(
        for indices: C,
        deltas: [(busy: UInt64, total: UInt64)]
    ) -> Double? where C.Element == Int {
        let sums = indices.reduce(into: (busy: UInt64(0), total: UInt64(0))) { result, index in
            result.busy += deltas[index].busy
            result.total += deltas[index].total
        }
        guard sums.total > 0 else { return nil }
        let value = Double(sums.busy) / Double(sums.total) * 100
        guard value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}

struct DiskCounters: Equatable, Sendable {
    let readBytes: UInt64
    let writtenBytes: UInt64
}

struct DiskRates: Equatable, Sendable {
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let smoothedReadBytesPerSecond: Double
    let smoothedWriteBytesPerSecond: Double
}

struct DiskBindingRetryState: Sendable {
    private var nextAttempt: ContinuousClock.Instant?

    func shouldAttempt(at instant: ContinuousClock.Instant) -> Bool {
        nextAttempt.map { instant >= $0 } ?? true
    }

    mutating func recordFailure(at instant: ContinuousClock.Instant) {
        nextAttempt = instant.advanced(by: .seconds(10))
    }

    mutating func recordSuccess() {
        nextAttempt = nil
    }

    mutating func reset() {
        nextAttempt = nil
    }
}

enum SystemDiskIdentityValidator {
    static func isInternalWhole(mediaWhole: Bool?, deviceInternal: Bool?) -> Bool {
        mediaWhole == true && deviceInternal == true
    }
}

struct DiskRateCalculator: Sendable {
    private var baseline: (counters: DiskCounters, instant: ContinuousClock.Instant)?
    private var recentRead: [Double] = []
    private var recentWrite: [Double] = []

    mutating func reset() {
        baseline = nil
        recentRead.removeAll(keepingCapacity: true)
        recentWrite.removeAll(keepingCapacity: true)
    }

    mutating func sample(
        counters: DiskCounters,
        at instant: ContinuousClock.Instant
    ) -> DiskRates? {
        guard let baseline else {
            self.baseline = (counters, instant)
            return nil
        }
        self.baseline = (counters, instant)

        guard counters.readBytes >= baseline.counters.readBytes,
              counters.writtenBytes >= baseline.counters.writtenBytes else {
            recentRead.removeAll(keepingCapacity: true)
            recentWrite.removeAll(keepingCapacity: true)
            return nil
        }

        let elapsed = Double((instant - baseline.instant).components.seconds)
            + Double((instant - baseline.instant).components.attoseconds) / 1e18
        guard elapsed > 0 else { return nil }

        let read = Double(counters.readBytes - baseline.counters.readBytes) / elapsed
        let write = Double(counters.writtenBytes - baseline.counters.writtenBytes) / elapsed
        recentRead.append(read)
        recentWrite.append(write)
        if recentRead.count > 3 {
            recentRead.removeFirst()
            recentWrite.removeFirst()
        }
        return DiskRates(
            readBytesPerSecond: read,
            writeBytesPerSecond: write,
            smoothedReadBytesPerSecond: recentRead.reduce(0, +) / Double(recentRead.count),
            smoothedWriteBytesPerSecond: recentWrite.reduce(0, +) / Double(recentWrite.count)
        )
    }
}

struct NetworkCounters: Equatable, Sendable {
    let downBytes: UInt64
    let upBytes: UInt64
}

struct NetworkRates: Equatable, Sendable {
    let downBytesPerSecond: Double
    let upBytesPerSecond: Double
    let smoothedDownBytesPerSecond: Double
    let smoothedUpBytesPerSecond: Double
}

struct NetworkRateCalculator: Sendable {
    private var baseline: (counters: NetworkCounters, instant: ContinuousClock.Instant)?
    private var recentDown: [Double] = []
    private var recentUp: [Double] = []

    mutating func reset() {
        baseline = nil
        recentDown.removeAll(keepingCapacity: true)
        recentUp.removeAll(keepingCapacity: true)
    }

    mutating func sample(
        counters: NetworkCounters,
        at instant: ContinuousClock.Instant
    ) -> NetworkRates? {
        guard let baseline else {
            self.baseline = (counters, instant)
            return nil
        }
        self.baseline = (counters, instant)

        guard counters.downBytes >= baseline.counters.downBytes,
              counters.upBytes >= baseline.counters.upBytes else {
            recentDown.removeAll(keepingCapacity: true)
            recentUp.removeAll(keepingCapacity: true)
            return nil
        }

        let elapsed = Double((instant - baseline.instant).components.seconds)
            + Double((instant - baseline.instant).components.attoseconds) / 1e18
        guard elapsed > 0 else { return nil }

        let down = Double(counters.downBytes - baseline.counters.downBytes) / elapsed
        let up = Double(counters.upBytes - baseline.counters.upBytes) / elapsed
        recentDown.append(down)
        recentUp.append(up)
        if recentDown.count > 3 {
            recentDown.removeFirst()
            recentUp.removeFirst()
        }
        return NetworkRates(
            downBytesPerSecond: down,
            upBytesPerSecond: up,
            smoothedDownBytesPerSecond: recentDown.reduce(0, +) / Double(recentDown.count),
            smoothedUpBytesPerSecond: recentUp.reduce(0, +) / Double(recentUp.count)
        )
    }
}

struct VMMemoryPageCounts: Equatable, Sendable {
    let free: UInt64
    let active: UInt64
    let inactive: UInt64
    let speculative: UInt64
    let wired: UInt64
    let purgeable: UInt64
    let fileBacked: UInt64
    let compressed: UInt64
}

struct MemoryByteComposition: Equatable, Sendable {
    let used: UInt64
    let cached: UInt64
    let compressed: UInt64
}

enum MemoryMetricsCalculator {
    static func calculate(
        pages: VMMemoryPageCounts,
        pageSize: UInt64,
        totalBytes: UInt64
    ) -> Result<MemoryByteComposition, SystemMetricsProviderError> {
        // active + inactive + speculative contains both anonymous and file-backed
        // pages. The component check below verifies those categories do not overlap
        // impossibly. Memory Used follows Activity Monitor's residual accounting:
        // physical memory minus free and reclaimable cached pages. Compressed is
        // reported separately and is not added again to that residual.
        let resident = pages.active + pages.inactive + pages.speculative
        guard resident >= pages.fileBacked + pages.purgeable else {
            return .failure(.malformedValue(domain: "memory", field: "pageComposition"))
        }
        let cachedPages = pages.fileBacked + pages.purgeable
        let unavailablePages = pages.free + cachedPages
        let (unavailableBytes, unavailableOverflow) = unavailablePages.multipliedReportingOverflow(by: pageSize)
        let (cached, cachedOverflow) = cachedPages.multipliedReportingOverflow(by: pageSize)
        let (compressed, compressedOverflow) = pages.compressed.multipliedReportingOverflow(by: pageSize)
        guard !unavailableOverflow,
              !cachedOverflow,
              !compressedOverflow,
              unavailableBytes <= totalBytes else {
            return .failure(.malformedValue(domain: "memory", field: "byteComposition"))
        }
        let used = totalBytes - unavailableBytes
        return .success(MemoryByteComposition(used: used, cached: cached, compressed: compressed))
    }
}

enum StorageHealth: Equatable, Sendable {
    case normal
    case warning
    case critical
    case unavailable
}

enum StorageThresholdCalculator {
    static let gibibyte = UInt64(1_073_741_824)

    static func health(totalBytes: UInt64?, availableBytes: UInt64?) -> StorageHealth {
        guard let totalBytes, let availableBytes, availableBytes <= totalBytes else {
            return .unavailable
        }
        let warning = max(UInt64(Double(totalBytes) * 0.05), 10 * gibibyte)
        let critical = max(UInt64(Double(totalBytes) * 0.02), 5 * gibibyte)
        if availableBytes <= critical { return .critical }
        if availableBytes <= warning { return .warning }
        return .normal
    }
}

enum SensorValueValidator {
    static func utilization(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    static func temperature(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (-10...125).contains(value) else { return nil }
        return value
    }

    static func fanRPM(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func temperatureDomain(for key: String) -> MonitorMetricID? {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return .cpu }
        if key.hasPrefix("Tg") { return .gpu }
        return nil
    }
}

struct SanitizedFanPayload: Equatable, Sendable {
    let metrics: [FanMetrics]
    let availability: MetricAvailability
}

enum SensorPayloadSanitizer {
    static func utilizationReading(_ value: Double?, sampledAt: Date) -> MetricReading<Double> {
        reading(value, source: .agxRegistry, sampledAt: sampledAt, validator: SensorValueValidator.utilization)
    }

    static func temperatureReading(_ values: [Double]?, sampledAt: Date) -> MetricReading<Double> {
        guard let values else {
            return MetricReading(value: nil, availability: .unavailable, source: .appleSMC, sampledAt: sampledAt)
        }
        let valid = values.compactMap { SensorValueValidator.temperature($0) }
        guard valid.count == values.count, let maximum = valid.max() else {
            return MetricReading(value: nil, availability: .failed, source: .appleSMC, sampledAt: sampledAt)
        }
        return MetricReading(value: maximum, availability: .available, source: .appleSMC, sampledAt: sampledAt)
    }

    static func fans(hasFanHardware: Bool, rpmValues: [Double]) -> SanitizedFanPayload {
        guard hasFanHardware else {
            return SanitizedFanPayload(
                metrics: [],
                availability: rpmValues.isEmpty ? .unavailable : .failed
            )
        }
        guard !rpmValues.isEmpty else {
            return SanitizedFanPayload(metrics: [], availability: .unavailable)
        }
        let valid = rpmValues.compactMap { SensorValueValidator.fanRPM($0) }
        guard valid.count == rpmValues.count else {
            return SanitizedFanPayload(metrics: [], availability: .failed)
        }
        return SanitizedFanPayload(
            metrics: valid.enumerated().map { index, rpm in
                FanMetrics(id: index, name: "Fan \(index + 1)", rpm: rpm)
            },
            availability: .available
        )
    }

    private static func reading(
        _ value: Double?,
        source: MonitorSource,
        sampledAt: Date,
        validator: (Double?) -> Double?
    ) -> MetricReading<Double> {
        guard let value else {
            return MetricReading(value: nil, availability: .unavailable, source: source, sampledAt: sampledAt)
        }
        guard let valid = validator(value) else {
            return MetricReading(value: nil, availability: .failed, source: source, sampledAt: sampledAt)
        }
        return MetricReading(value: valid, availability: .available, source: source, sampledAt: sampledAt)
    }
}
