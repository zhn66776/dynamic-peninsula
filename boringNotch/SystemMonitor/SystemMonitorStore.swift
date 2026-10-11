import AppKit
import Combine
import Defaults
import Foundation

@MainActor
final class SystemMonitorStore: ObservableObject {
    enum SuspensionReason: Hashable {
        case screenLock
        case displaySleep
        case systemSleep
    }

    static let shared = SystemMonitorStore(sampler: .shared)

    @Published private(set) var snapshot = SystemMonitorSnapshot.placeholder()
    @Published private(set) var history = SystemMonitorHistory()
    @Published var selectedMetric: MonitorMetricID?
    @Published private(set) var activeAlert: SystemMonitorAlert?

    private let sampler: SystemMonitorSampler
    private var hasStarted = false
    private var enabled = true
    private var monitorVisible = false
    private var visibleWindows = Set<ObjectIdentifier>()
    private var suspensionReasons = Set<SuspensionReason>()
    private var streamTask: Task<Void, Never>?
    private var interactionGraceTask: Task<Void, Never>?
    private var interactionGraceUntil = Date.distantPast
    private var alertController = SystemMonitorAlertController()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notificationObservers: [NSObjectProtocol] = []

    init(sampler: SystemMonitorSampler) {
        self.sampler = sampler
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        enabled = Defaults[.systemMonitorEnabled]
        registerLifecycleObservers()
        streamTask = Task { [weak self, sampler] in
            let stream = await sampler.snapshots()
            await sampler.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
            await sampler.setContext(self?.samplingContext ?? .disabled)
            await sampler.start()
            for await value in stream {
                guard let self, !Task.isCancelled else { return }
                self.receive(value)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        interactionGraceTask?.cancel()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
        hasStarted = false
        history = SystemMonitorHistory()
        Task { [sampler] in await sampler.stop() }
    }

    func setMonitorVisible(_ visible: Bool) {
        guard monitorVisible != visible else { return }
        monitorVisible = visible
        if !visible { selectedMetric = nil }
        updateSamplerContext()
    }

    func setMonitorVisible(_ visible: Bool, windowID: ObjectIdentifier) {
        if visible { visibleWindows.insert(windowID) }
        else { visibleWindows.remove(windowID) }
        setMonitorVisible(!visibleWindows.isEmpty)
    }

    func setEnabled(_ isEnabled: Bool) {
        guard enabled != isEnabled else { return }
        enabled = isEnabled
        if !isEnabled {
            selectedMetric = nil
            dismissAlert()
            if BoringViewCoordinator.shared.currentView == .monitor {
                BoringViewCoordinator.shared.currentView = .home
            }
        }
        updateSamplerContext()
    }

    func setSuspended(_ reason: SuspensionReason, active: Bool) {
        let wasSuspended = !suspensionReasons.isEmpty
        if active {
            guard suspensionReasons.insert(reason).inserted else { return }
        } else {
            guard suspensionReasons.remove(reason) != nil else { return }
        }
        let context = samplingContext
        if wasSuspended, suspensionReasons.isEmpty, enabled {
            Task { [sampler] in
                await sampler.handleWake()
                await sampler.setContext(context)
            }
        } else {
            Task { [sampler] in await sampler.setContext(context) }
        }
    }

    func noteUserInteraction() {
        interactionGraceUntil = Date().addingTimeInterval(0.5)
        interactionGraceTask?.cancel()
        interactionGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.reevaluateAlert()
        }
    }

    func openAlert(_ alert: SystemMonitorAlert) {
        selectedMetric = alert.metric
        BoringViewCoordinator.shared.currentView = .monitor
        dismissAlert()
    }

    func receive(_ newSnapshot: SystemMonitorSnapshot) {
        guard enabled else { return }
        if snapshot != newSnapshot { snapshot = newSnapshot }
        if monitorVisible { appendHistory(from: newSnapshot) }
        evaluateAlert(for: newSnapshot)
    }

    func statistics() async -> SystemMonitorSamplerStatistics {
        await sampler.currentStatistics()
    }

    private var samplingContext: SamplingContext {
        guard enabled else { return .disabled }
        guard suspensionReasons.isEmpty else { return .suspended }
        return monitorVisible ? .foreground : .background
    }

    private var interactionBusy: Bool {
        SharingStateManager.shared.preventNotchClose || Date() < interactionGraceUntil
    }

    private func updateSamplerContext() {
        let context = samplingContext
        Task { [sampler] in await sampler.setContext(context) }
    }

    private func appendHistory(from value: SystemMonitorSnapshot) {
        var updated = history
        append(value.cpu.totalPercent, sequence: value.sequence, to: &updated.cpu)
        append(value.gpu.utilizationPercent, sequence: value.sequence, to: &updated.gpu)
        let temperatures = [value.thermal.cpuMaxCelsius, value.thermal.gpuMaxCelsius]
            .filter { $0.availability == .available }
        if let date = temperatures.map(\.sampledAt).max(),
           let maximum = temperatures.compactMap(\.value).max(),
           updated.temperature.elements.last?.timestamp != date {
            updated.temperature.append(.init(id: value.sequence, timestamp: date, value: maximum))
        }
        if let used = value.memory.usedBytes, value.memory.totalBytes > 0,
           updated.memory.elements.last?.timestamp != value.sampledAt {
            updated.memory.append(.init(
                id: value.sequence,
                timestamp: value.sampledAt,
                value: Double(used) / Double(value.memory.totalBytes) * 100
            ))
        }
        appendRate(value.storage.smoothedReadBytesPerSecond, value: value, to: &updated.storageRead)
        appendRate(value.storage.smoothedWriteBytesPerSecond, value: value, to: &updated.storageWrite)
        appendRate(value.network.smoothedDownBytesPerSecond, value: value, to: &updated.networkDown)
        appendRate(value.network.smoothedUpBytesPerSecond, value: value, to: &updated.networkUp)
        updated.trim(before: value.sampledAt.addingTimeInterval(-60))
        if updated != history { history = updated }
    }

    private func append(
        _ reading: MetricReading<Double>,
        sequence: UInt64,
        to buffer: inout FixedRingBuffer<MonitorHistoryPoint>
    ) {
        guard reading.availability == .available, let value = reading.value,
              buffer.elements.last?.timestamp != reading.sampledAt else { return }
        buffer.append(.init(id: sequence, timestamp: reading.sampledAt, value: value))
    }

    private func appendRate(
        _ rate: Double?,
        value: SystemMonitorSnapshot,
        to buffer: inout FixedRingBuffer<MonitorHistoryPoint>
    ) {
        guard let rate, buffer.elements.last?.timestamp != value.sampledAt else { return }
        buffer.append(.init(id: value.sequence, timestamp: value.sampledAt, value: rate))
    }

    private func evaluateAlert(for value: SystemMonitorSnapshot) {
        let alert = alertController.evaluate(
            snapshot: value,
            at: Date(),
            enabled: Defaults[.systemMonitorBackgroundAlertsEnabled],
            interactionBusy: interactionBusy
        )
        if let alert { present(alert) }
    }

    private func reevaluateAlert() {
        evaluateAlert(for: snapshot)
    }

    private func present(_ alert: SystemMonitorAlert) {
        activeAlert = alert
        BoringViewCoordinator.shared.systemMonitorAlert = alert
        // No auto-dismiss timer: the dropdown stays up until the user
        // taps it (openAlert) or its close button (dismissAlert).
    }

    /// Dismisses the on-screen alert dropdown. Called when the user taps
    /// it (openAlert), taps its close button, or monitoring is disabled.
    func dismissAlert() {
        activeAlert = nil
        BoringViewCoordinator.shared.systemMonitorAlert = nil
    }

    private func registerLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.setSuspended(.systemSleep, active: true) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.setSuspended(.systemSleep, active: false) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.setSuspended(.displaySleep, active: true) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.setSuspended(.displaySleep, active: false) }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { await self.sampler.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled) }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .sharingDidFinish, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.reevaluateAlert() }
        })
    }
}
