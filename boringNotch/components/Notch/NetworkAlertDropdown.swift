//
//  NetworkAlertDropdown.swift
//  boringNotch
//
//  Dropdown pill for NetworkConnectivityMonitor's persistent "no internet"
//  alert. Same capsule shape/placement as SystemMonitorAlertDropdown, kept
//  as its own view since this one has nothing to open on tap — just a
//  message and a dismiss button.
//

import SwiftUI

struct NetworkAlertDropdown: View {
    let alert: NetworkOutageAlert
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.red)
            Text("Internet connection lost")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

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
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        .fixedSize()
    }
}
