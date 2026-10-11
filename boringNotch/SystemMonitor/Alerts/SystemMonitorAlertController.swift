import Foundation

enum SystemMonitorAlertKind: String, CaseIterable, Sendable {
    case thermalSerious
    case thermalCritical
    case memoryWarning
    case memoryCritical
    case storageWarning
    case storageCritical

    var metric: MonitorMetricID {
        switch self {
        case .thermalSerious, .thermalCritical: return .thermal
        case .memoryWarning, .memoryCritical: return .memory
        case .storageWarning, .storageCritical: return .storage
        }
    }

    var isCritical: Bool {
        switch self {
        case .thermalCritical, .memoryCritical, .storageCritical: return true
        default: return false
        }
    }
}

struct SystemMonitorAlert: Identifiable, Equatable, Sendable {
    let id: UInt64
    let kind: SystemMonitorAlertKind
    let createdAt: Date

    var metric: MonitorMetricID { kind.metric }
}

struct SystemMonitorAlertController: Sendable {
    private enum Level: Int, Sendable {
        case unavailable = -1
        case normal = 0
        case warning = 1
        case critical = 2
    }

    private var previous: [MonitorMetricID: Level] = [:]
    private var lastShown: [SystemMonitorAlertKind: Date] = [:]
    private var pending: (kind: SystemMonitorAlertKind, createdAt: Date)?
    private var nextID: UInt64 = 1

    mutating func evaluate(
        snapshot: SystemMonitorSnapshot,
        at date: Date,
        enabled: Bool,
        interactionBusy: Bool
    ) -> SystemMonitorAlert? {
        let current = levels(for: snapshot)
        let candidates = current.compactMap { metric, level -> SystemMonitorAlertKind? in
            defer {
                if level != .unavailable { previous[metric] = level }
            }
            guard enabled, level != .unavailable else { return nil }
            let old = previous[metric]
            guard level.rawValue >= Level.warning.rawValue else { return nil }
            guard old == nil || old == .normal || old == .unavailable || level.rawValue > old!.rawValue else {
                return nil
            }
            return kind(for: metric, level: level)
        }

        if !enabled {
            pending = nil
            return nil
        }

        if interactionBusy {
            if let candidate = highest(candidates) {
                if pending == nil || candidate.isCritical && pending?.kind.isCritical == false {
                    pending = (candidate, date)
                }
            }
            return nil
        }

        var ready = candidates
        if let pending {
            self.pending = nil
            if date.timeIntervalSince(pending.createdAt) <= 30,
               isStillActive(pending.kind, levels: current) {
                ready.append(pending.kind)
            }
        }
        guard let kind = highest(ready), cooldownAllows(kind, at: date) else { return nil }
        lastShown[kind] = date
        let alert = SystemMonitorAlert(id: nextID, kind: kind, createdAt: date)
        nextID += 1
        return alert
    }

    private func levels(for snapshot: SystemMonitorSnapshot) -> [MonitorMetricID: Level] {
        let thermal: Level
        switch snapshot.thermal.systemLevel {
        case .serious: thermal = .warning
        case .critical: thermal = .critical
        case .nominal, .fair: thermal = .normal
        case .unavailable: thermal = .unavailable
        }

        let memory: Level
        switch snapshot.memory.pressure {
        case .normal: memory = .normal
        case .warning: memory = .warning
        case .critical: memory = .critical
        case .unavailable: memory = .unavailable
        }

        let storage: Level
        switch StorageThresholdCalculator.health(
            totalBytes: snapshot.storage.totalBytes,
            availableBytes: snapshot.storage.availableForImportantUsageBytes
        ) {
        case .normal: storage = .normal
        case .warning: storage = .warning
        case .critical: storage = .critical
        case .unavailable: storage = .unavailable
        }
        return [.thermal: thermal, .memory: memory, .storage: storage]
    }

    private func kind(for metric: MonitorMetricID, level: Level) -> SystemMonitorAlertKind? {
        switch (metric, level) {
        case (.thermal, .warning): return .thermalSerious
        case (.thermal, .critical): return .thermalCritical
        // Alert on critical memory pressure.
        case (.memory, .critical): return .memoryCritical
        case (.storage, .warning): return .storageWarning
        case (.storage, .critical): return .storageCritical
        default: return nil
        }
    }

    private func highest(_ candidates: [SystemMonitorAlertKind]) -> SystemMonitorAlertKind? {
        candidates.max { lhs, rhs in
            if lhs.isCritical != rhs.isCritical { return !lhs.isCritical }
            return lhs.rawValue < rhs.rawValue
        }
    }

    private func cooldownAllows(_ kind: SystemMonitorAlertKind, at date: Date) -> Bool {
        guard let last = lastShown[kind] else { return true }
        return date.timeIntervalSince(last) >= 600
    }

    private func isStillActive(
        _ kind: SystemMonitorAlertKind,
        levels: [MonitorMetricID: Level]
    ) -> Bool {
        guard let level = levels[kind.metric] else { return false }
        return kind.isCritical ? level == .critical : level.rawValue >= Level.warning.rawValue
    }
}
