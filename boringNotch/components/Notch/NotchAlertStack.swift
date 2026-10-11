//
//  NotchAlertStack.swift
//  boringNotch
//
//  Orders the independent memory/thermal/storage alert and the portfolio
//  notification into a single top-to-bottom stack: whichever one started
//  showing first stays on top, and each is dismissed independently. There's
//  no shared "notification center" object here on purpose — each source
//  (SystemMonitorStore, StockPortfolioMonitor) still owns its own
//  presented/dismissed state; this just orders the two for display.
//

import Foundation

enum NotchAlertKind {
    case systemMonitor(SystemMonitorAlert)
#if !PUBLIC_RELEASE
    case stockPortfolio(PortfolioSnapshot)
#endif
    case network(NetworkOutageAlert)
}

struct NotchAlertItem: Identifiable {
    let id: String
    let presentedAt: Date
    let kind: NotchAlertKind
}

private func baseNotchAlerts(
    systemMonitorAlert: SystemMonitorAlert?,
    networkAlert: NetworkOutageAlert?
) -> [NotchAlertItem] {
    var items: [NotchAlertItem] = []
    if let alert = systemMonitorAlert {
        items.append(NotchAlertItem(id: "systemMonitor", presentedAt: alert.createdAt, kind: .systemMonitor(alert)))
    }
    if let networkAlert {
        items.append(NotchAlertItem(id: "network", presentedAt: networkAlert.since, kind: .network(networkAlert)))
    }
    return items.sorted { $0.presentedAt < $1.presentedAt }
}

#if !PUBLIC_RELEASE
func orderedNotchAlerts(
    systemMonitorAlert: SystemMonitorAlert?,
    stockNotification: PortfolioSnapshot?,
    stockPresentedAt: Date?,
    networkAlert: NetworkOutageAlert?
) -> [NotchAlertItem] {
    var items = baseNotchAlerts(
        systemMonitorAlert: systemMonitorAlert,
        networkAlert: networkAlert
    )
    if let snapshot = stockNotification, let presentedAt = stockPresentedAt {
        items.append(NotchAlertItem(id: "stockPortfolio", presentedAt: presentedAt, kind: .stockPortfolio(snapshot)))
    }
    return items.sorted { $0.presentedAt < $1.presentedAt }
}
#else
func orderedNotchAlerts(
    systemMonitorAlert: SystemMonitorAlert?,
    networkAlert: NetworkOutageAlert?
) -> [NotchAlertItem] {
    baseNotchAlerts(
        systemMonitorAlert: systemMonitorAlert,
        networkAlert: networkAlert
    )
}
#endif
