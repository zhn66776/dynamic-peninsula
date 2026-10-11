//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: LocalizedStringKey
    let icon: String
    let view: NotchViews
}

// No tab buttons for .agent / .claude — the Codex/Claude quota badges
// (QuotaBadgeView) next to the camera open them directly instead.
let tabs: [TabModel] = {
    var tabs = [
        TabModel(label: "Home", icon: "music.note", view: .home),
        TabModel(label: "System Monitor", icon: "gauge.with.dots.needle.67percent", view: .monitor),
        TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
        TabModel(label: "Clipboard", icon: "doc.on.clipboard", view: .clipboard),
    ]
#if !PUBLIC_RELEASE
    tabs.append(TabModel(label: "Portfolio", icon: "chart.line.uptrend.xyaxis", view: .portfolio))
#endif
    return tabs
}()

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.systemMonitorEnabled) private var systemMonitorEnabled
#if !PUBLIC_RELEASE
    @Default(.portfolioModuleEnabled) private var portfolioModuleEnabled
#endif
    @Namespace var animation
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs.filter { tab in
                guard tab.view != .monitor || systemMonitorEnabled else { return false }
#if !PUBLIC_RELEASE
                return tab.view != .portfolio || portfolioModuleEnabled
#else
                return true
#endif
            }) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 24)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .accessibilityLabel(Text(tab.label))
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
