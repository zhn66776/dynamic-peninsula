import Defaults
import SwiftUI

private enum MonitorPalette {
    static let cpu = Color(red: 54 / 255, green: 153 / 255, blue: 1)
    static let gpu = Color(red: 169 / 255, green: 112 / 255, blue: 1)
    static let thermal = Color(red: 1, green: 159 / 255, blue: 67 / 255)
    static let critical = Color(red: 1, green: 83 / 255, blue: 73 / 255)
    static let fan = Color(red: 1, green: 214 / 255, blue: 90 / 255)
    static let memory = Color(red: 67 / 255, green: 209 / 255, blue: 122 / 255)
    static let storage = Color(red: 57 / 255, green: 213 / 255, blue: 230 / 255)
    static let network = Color(red: 137 / 255, green: 221 / 255, blue: 89 / 255)
}

struct SystemMonitorView: View {
    @ObservedObject private var store = SystemMonitorStore.shared
    @ObservedObject private var networkMonitor = NetworkConnectivityMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                metricCard(.cpu)
                metricCard(.gpu)
                metricCard(.thermal)
            }
            .frame(height: 61)

            Group {
                if let selected = store.selectedMetric {
                    SystemMetricDetailView(
                        metric: selected,
                        snapshot: store.snapshot,
                        history: store.history,
                        onBack: { select(nil) }
                    )
                    .id(selected)
                    .transition(reduceMotion ? .identity : .opacity)
                } else {
                    HStack(spacing: 7) {
                        metricCard(.memory)
                        metricCard(.storage)
                        metricCard(.network)
                    }
                    .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .frame(height: 55)
        }
        .frame(maxWidth: .infinity, maxHeight: 123)
        .padding(.horizontal, 4)
        .onDisappear { store.selectedMetric = nil }
    }

    @ViewBuilder
    private func metricCard(_ metric: MonitorMetricID) -> some View {
        let presentation = MonitorPresentation(metric: metric, snapshot: store.snapshot, history: store.history)
        SystemMetricCard(
            title: presentation.title,
            primaryText: presentation.primary,
            secondaryText: presentation.secondary,
            tertiaryText: presentation.tertiary,
            progress: presentation.progress,
            points: presentation.points,
            tint: presentation.tint,
            secondaryTint: presentation.secondaryTint,
            warning: presentation.warning,
            statusIcon: metric == .network ? networkStatusIcon : nil,
            accessibilityValue: presentation.accessibilityValue
        ) {
            select(store.selectedMetric == metric ? nil : metric)
        }
    }

    // Green check when the internet is reachable, red exclamation when
    // NetworkConnectivityMonitor has flagged it down — same source of truth
    // as the notch's own "Internet connection lost" dropdown, just surfaced
    // right on the Network card too since that dropdown only shows while
    // the notch is closed.
    private var networkStatusIcon: (systemName: String, color: Color) {
        networkMonitor.isOffline
            ? ("exclamationmark.circle.fill", .red)
            : ("checkmark.circle.fill", .green)
    }

    private func select(_ metric: MonitorMetricID?) {
        if reduceMotion {
            store.selectedMetric = metric
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                store.selectedMetric = metric
            }
        }
    }
}

private struct SystemMetricCard: View {
    let title: String
    let primaryText: String
    let secondaryText: String?
    let tertiaryText: String?
    let progress: Double?
    let points: [MonitorHistoryPoint]
    let tint: Color
    let secondaryTint: Color?
    let warning: Bool
    let statusIcon: (systemName: String, color: Color)?
    let accessibilityValue: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                    if warning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8, weight: .bold))
                    }
                    if let statusIcon {
                        Image(systemName: statusIcon.systemName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(statusIcon.color)
                    }
                    Spacer(minLength: 2)
                    Text(primaryText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                }
                if let secondaryText {
                    Text(secondaryText)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let tertiaryText {
                    Text(tertiaryText)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(secondaryTint ?? tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !points.isEmpty {
                    SystemSparkline(points: points, tint: tint)
                        .frame(height: 10)
                } else {
                    Capsule()
                        .fill(.white.opacity(0.10))
                        .overlay(alignment: .leading) {
                            if let progress {
                                GeometryReader { proxy in
                                    Capsule().fill(tint).frame(width: proxy.size.width * min(max(progress, 0), 1))
                                }
                            }
                        }
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text(String(localized: "Shows details for this metric")))
    }
}

private struct SystemSparkline: View {
    let points: [MonitorHistoryPoint]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            path(in: proxy.size)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    private func path(in size: CGSize) -> Path {
        guard points.count > 1 else { return Path() }
        let values = points.map(\.value)
        let range = displayRange(values)
        let span = max(range.upperBound - range.lowerBound, 1)
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = (value - range.lowerBound) / span
            let y = size.height * CGFloat(1 - min(max(normalized, 0), 1))
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    private func displayRange(_ values: [Double]) -> ClosedRange<Double> {
        if values.allSatisfy({ (0...100).contains($0) }) { return 0...100 }
        return 0...max(values.max() ?? 1, 1)
    }
}

private struct SystemMetricDetailView: View {
    let metric: MonitorMetricID
    let snapshot: SystemMonitorSnapshot
    let history: SystemMonitorHistory
    let onBack: () -> Void

    var body: some View {
        let presentation = MonitorPresentation(metric: metric, snapshot: snapshot, history: history)
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "Back")))

            VStack(alignment: .leading, spacing: 3) {
                if metric == .storage || metric == .memory {
                    compactFields(presentation: presentation)
                } else {
                    HStack {
                        detailTitle(presentation)
                        ForEach(detailFields, id: \.0) { label, value in
                            Text("\(label) \(value)")
                                .font(.system(size: 8, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                }
                SystemSparkline(points: presentation.points, tint: presentation.tint)
                    .frame(height: metric == .storage || metric == .memory ? 10 : 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(presentation.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { onBack() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func detailTitle(_ presentation: MonitorPresentation) -> some View {
        Text(presentation.title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(presentation.tint)
    }

    private func compactFields(presentation: MonitorPresentation) -> some View {
        let fields = detailFields
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                detailTitle(presentation)
                ForEach(Array(fields.prefix(2)), id: \.0) { label, value in
                    detailField(label, value)
                }
            }
            HStack(spacing: 6) {
                ForEach(Array(fields.dropFirst(2)), id: \.0) { label, value in
                    detailField(label, value)
                }
            }
        }
    }

    private func detailField(_ label: String, _ value: String) -> some View {
        Text("\(label) \(value)")
            .font(.system(size: 7.5, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var detailFields: [(String, String)] {
        switch metric {
        case .cpu:
            return [
                (String(localized: "Total"), visible(snapshot.cpu.totalPercent).map(SystemMetricFormatter.percent) ?? "—"),
                ("P", visible(snapshot.cpu.performanceCorePercent).map(SystemMetricFormatter.percent) ?? "—"),
                ("E", visible(snapshot.cpu.efficiencyCorePercent).map(SystemMetricFormatter.percent) ?? "—"),
                (String(localized: "Cores"), "\(snapshot.cpu.logicalCoreCount)")
            ]
        case .gpu:
            return [
                (String(localized: "Total"), visible(snapshot.gpu.utilizationPercent).map(SystemMetricFormatter.percent) ?? "—"),
                (String(localized: "Renderer"), visible(snapshot.gpu.rendererPercent).map(SystemMetricFormatter.percent) ?? "—"),
                (String(localized: "Tiler"), visible(snapshot.gpu.tilerPercent).map(SystemMetricFormatter.percent) ?? "—"),
                (String(localized: "Memory"), snapshot.gpu.memoryBytes.availability == .available ? SystemMetricFormatter.bytes(snapshot.gpu.memoryBytes.value) : "—")
            ]
        case .thermal:
            var values = [
                ("CPU", visible(snapshot.thermal.cpuMaxCelsius).map(SystemMetricFormatter.celsius) ?? "—"),
                ("GPU", visible(snapshot.thermal.gpuMaxCelsius).map(SystemMetricFormatter.celsius) ?? "—"),
                (String(localized: "Thermal State"), thermalText(snapshot.thermal.systemLevel))
            ]
            if snapshot.thermal.hasFanHardware {
                if snapshot.thermal.fanAvailability == .available {
                    values.append(contentsOf: snapshot.thermal.fans.map {
                        ("\(String(localized: "Fan")) \($0.id + 1)",
                         String(format: "%.0f RPM", locale: .current, $0.rpm))
                    })
                } else {
                    values.append((
                        String(localized: "Fan"),
                        "— \(String(localized: "Temporarily unavailable"))"
                    ))
                }
            }
            return values
        case .memory:
            return [
                (String(localized: "Pressure"), memoryPressureText(snapshot.memory.pressure)),
                (String(localized: "Used"), SystemMetricFormatter.memory(used: snapshot.memory.usedBytes, total: snapshot.memory.totalBytes)),
                (String(localized: "Cached"), SystemMetricFormatter.bytes(snapshot.memory.cachedBytes)),
                (String(localized: "Compressed"), SystemMetricFormatter.bytes(snapshot.memory.compressedBytes)),
                (String(localized: "Swap"), SystemMetricFormatter.bytes(snapshot.memory.swapUsedBytes))
            ]
        case .storage:
            let usedPercent: String = {
                guard let total = snapshot.storage.totalBytes,
                      let available = snapshot.storage.availableForImportantUsageBytes,
                      total > 0, available <= total else { return "—" }
                return SystemMetricFormatter.percent(Double(total - available) / Double(total) * 100)
            }()
            return [
                (String(localized: "Available"), SystemMetricFormatter.storageCapacity(snapshot.storage.availableForImportantUsageBytes)),
                (String(localized: "Used"), usedPercent),
                (String(localized: "Read"), SystemMetricFormatter.rate(snapshot.storage.instantaneousReadBytesPerSecond)),
                (String(localized: "Write"), SystemMetricFormatter.rate(snapshot.storage.instantaneousWriteBytesPerSecond)),
                (String(localized: "3s Read Avg"), SystemMetricFormatter.rate(snapshot.storage.smoothedReadBytesPerSecond)),
                (String(localized: "3s Write Avg"), SystemMetricFormatter.rate(snapshot.storage.smoothedWriteBytesPerSecond))
            ]
        case .network:
            return [
                (String(localized: "Down"), SystemMetricFormatter.rate(snapshot.network.instantaneousDownBytesPerSecond)),
                (String(localized: "Up"), SystemMetricFormatter.rate(snapshot.network.instantaneousUpBytesPerSecond)),
                (String(localized: "3s Down Avg"), SystemMetricFormatter.rate(snapshot.network.smoothedDownBytesPerSecond)),
                (String(localized: "3s Up Avg"), SystemMetricFormatter.rate(snapshot.network.smoothedUpBytesPerSecond))
            ]
        }
    }
}

private struct MonitorPresentation {
    let title: String
    let primary: String
    let secondary: String?
    let tertiary: String?
    let progress: Double?
    let points: [MonitorHistoryPoint]
    let tint: Color
    let secondaryTint: Color?
    let warning: Bool
    let accessibilityValue: String

    init(metric: MonitorMetricID, snapshot: SystemMonitorSnapshot, history: SystemMonitorHistory) {
        switch metric {
        case .cpu:
            let value = visible(snapshot.cpu.totalPercent)
            title = "CPU"
            primary = SystemMetricFormatter.percent(value)
            secondary = value == nil ? String(localized: "Temporarily unavailable") : nil
            tertiary = nil
            progress = value.map { $0 / 100 }
            points = history.cpu.elements
            tint = MonitorPalette.cpu
            secondaryTint = nil
            warning = false
        case .gpu:
            let value = visible(snapshot.gpu.utilizationPercent)
            title = "GPU"
            primary = SystemMetricFormatter.percent(value)
            secondary = value == nil ? String(localized: "Temporarily unavailable") : nil
            tertiary = nil
            progress = value.map { $0 / 100 }
            points = history.gpu.elements
            tint = MonitorPalette.gpu
            secondaryTint = nil
            warning = false
        case .thermal:
            let cpu = visible(snapshot.thermal.cpuMaxCelsius)
            let gpu = visible(snapshot.thermal.gpuMaxCelsius)
            let value = [cpu, gpu].compactMap { $0 }.max()
            title = String(localized: "Temperature")
            primary = SystemMetricFormatter.celsius(value)
            secondary = "CPU \(SystemMetricFormatter.celsius(cpu)) · GPU \(SystemMetricFormatter.celsius(gpu))"
            if snapshot.thermal.hasFanHardware {
                if snapshot.thermal.fanAvailability == .available {
                    tertiary = snapshot.thermal.fans.map {
                        String(
                            format: "%@ %d %.0f RPM",
                            locale: .current,
                            String(localized: "Fan"),
                            $0.id + 1,
                            $0.rpm
                        )
                    }.joined(separator: " · ")
                } else {
                    tertiary = "\(String(localized: "Fan")) — · \(String(localized: "Temporarily unavailable"))"
                }
            } else {
                tertiary = nil
            }
            progress = value.map { min(max(($0 - 20) / 90, 0), 1) }
            points = history.temperature.elements
            warning = [.serious, .critical].contains(snapshot.thermal.systemLevel)
            tint = warning ? MonitorPalette.critical : MonitorPalette.thermal
            secondaryTint = MonitorPalette.fan
        case .memory:
            title = String(localized: "Memory")
            primary = SystemMetricFormatter.memory(used: snapshot.memory.usedBytes, total: snapshot.memory.totalBytes)
            secondary = "\(String(localized: "Pressure")): \(memoryPressureText(snapshot.memory.pressure))"
            tertiary = nil
            progress = snapshot.memory.usedBytes.map { Double($0) / Double(snapshot.memory.totalBytes) }
            points = history.memory.elements
            tint = MonitorPalette.memory
            secondaryTint = nil
            warning = [.warning, .critical].contains(snapshot.memory.pressure)
        case .storage:
            let health = StorageThresholdCalculator.health(
                totalBytes: snapshot.storage.totalBytes,
                availableBytes: snapshot.storage.availableForImportantUsageBytes
            )
            title = String(localized: "Storage")
            primary = "\(SystemMetricFormatter.storageCapacity(snapshot.storage.availableForImportantUsageBytes)) \(String(localized: "available"))"
            secondary = "\(String(localized: "Read")) \(SystemMetricFormatter.rate(snapshot.storage.smoothedReadBytesPerSecond))  \(String(localized: "Write")) \(SystemMetricFormatter.rate(snapshot.storage.smoothedWriteBytesPerSecond))"
            tertiary = nil
            if let total = snapshot.storage.totalBytes,
               let available = snapshot.storage.availableForImportantUsageBytes,
               total > 0, available <= total {
                progress = Double(total - available) / Double(total)
            } else { progress = nil }
            points = history.storageRead.elements
            tint = MonitorPalette.storage
            secondaryTint = nil
            warning = health == .warning || health == .critical
        case .network:
            title = String(localized: "Network")
            primary = "↓ \(SystemMetricFormatter.rate(snapshot.network.smoothedDownBytesPerSecond))"
            secondary = "↑ \(SystemMetricFormatter.rate(snapshot.network.smoothedUpBytesPerSecond))"
            tertiary = nil
            progress = nil
            points = history.networkDown.elements
            tint = MonitorPalette.network
            secondaryTint = nil
            warning = false
        }
        accessibilityValue = [primary, secondary, tertiary, String(localized: "past 60 seconds")]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

struct SystemMonitorClosedActivity: View {
    @ObservedObject private var store = SystemMonitorStore.shared

    var body: some View {
        let value = visible(store.snapshot.cpu.totalPercent)
        HStack(spacing: 4) {
            Text("CPU")
            Text(SystemMetricFormatter.percent(value))
                .foregroundStyle(MonitorPalette.cpu)
        }
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("CPU"))
        .accessibilityValue(Text(SystemMetricFormatter.percent(value)))
    }
}

/// Dynamic-Island-style pill that hangs below the closed notch/camera
/// (see ContentView's mainLayout overlay) instead of widening the notch
/// pill itself sideways.
struct SystemMonitorAlertDropdown: View {
    let alert: SystemMonitorAlert
    let action: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: alert.kind.isCritical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(alert.kind.isCritical ? MonitorPalette.critical : MonitorPalette.thermal)
                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(message))
            .accessibilityHint(Text(String(localized: "Opens System Monitor details")))

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .glassAlertBackground()
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        // The dropdown is laid out as an overlay on top of the (narrow)
        // closed notch pill, which otherwise proposes that pill's
        // width down to this Text and truncates it — fixedSize makes
        // this pill ignore that proposal and size to its own content
        // instead, so the capsule grows/shrinks with message length.
        .fixedSize()
    }

    private var message: String {
        switch alert.kind {
        case .thermalSerious: return String(localized: "Mac is running warm; click for details")
        case .thermalCritical: return String(localized: "Mac thermal state is critical; reduce load")
        case .memoryWarning: return String(localized: "Memory pressure is elevated; click for details")
        case .memoryCritical: return String(localized: "Memory pressure is critical")
        case .storageWarning: return String(localized: "System disk space is low")
        case .storageCritical: return String(localized: "System disk space is critically low")
        }
    }
}

private extension View {
    func glassAlertBackground() -> some View {
        self.glassEffect(.regular, in: Capsule())
    }
}

private func visible<T>(_ reading: MetricReading<T>) -> T? {
    reading.availability == .available ? reading.value : nil
}

private func memoryPressureText(_ pressure: MemoryPressureLevel) -> String {
    switch pressure {
    case .normal: return String(localized: "Normal")
    case .warning: return String(localized: "Warning")
    case .critical: return String(localized: "Critical")
    case .unavailable: return String(localized: "Unavailable")
    }
}

private func thermalText(_ level: SystemThermalLevel) -> String {
    switch level {
    case .nominal: return String(localized: "Nominal")
    case .fair: return String(localized: "Fair")
    case .serious: return String(localized: "Serious")
    case .critical: return String(localized: "Critical")
    case .unavailable: return String(localized: "Unavailable")
    }
}
