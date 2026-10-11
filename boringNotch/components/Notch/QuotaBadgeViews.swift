//
//  QuotaBadgeViews.swift
//  boringNotch
//
//  The two weekly-remaining-quota badges flanking the camera — Codex on
//  the left (CodexQuotaMonitor), Claude on the right (ClaudeQuotaMonitor).
//  Drawn once by ContentView, fixed to the notch shape, so they sit at the
//  same absolute position open or closed. Clicking one opens the notch to
//  that agent's detail tab. Each sizes itself to the same album-art-sized
//  slot used throughout the closed notch.
//

import SwiftUI

extension QuotaProvider {
    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var detailView: NotchViews {
        switch self {
        case .codex: return .agent
        case .claude: return .claude
        }
    }

    /// Codex's badge uses the old Codex logo's blue-violet, Claude's is
    /// filled with Claude's coral, so the two numbers can't be mixed up.
    var badgeFill: Color {
        switch self {
        case .codex: return Color(red: 130 / 255, green: 110 / 255, blue: 255 / 255)
        case .claude: return Color(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        }
    }

    var badgeDigits: Color { .white }

    /// Tint for the incoming number after a drop — in the badge itself and
    /// in the full-pill reveal.
    var dropTint: Color {
        switch self {
        case .codex: return Color(red: 0x6f / 255, green: 0xc7 / 255, blue: 0xff / 255)
        case .claude: return Color(red: 1.00, green: 0.80, blue: 0.62)
        }
    }

    @ViewBuilder
    var logo: some View {
        switch self {
        case .codex:
            CodexLogoShape().fill(badgeFill, style: FillStyle(eoFill: true))
        case .claude:
            // The official mark (Assets.xcassets/ClaudeLogo, from
            // claude-color.svg), already in Claude's #D97757.
            Image("ClaudeLogo").resizable().scaledToFit()
        }
    }
}

/// On a drop (never on a rise, e.g. after a weekly reset) the old number
/// ghosts upward and fades while the new one — briefly tinted — rises in
/// from below to take its place.
struct QuotaBadgeView: View {
    let provider: QuotaProvider
    let remainingPercent: Int?

    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    @State private var outgoingValue: Int?
    @State private var outgoingOffset: CGFloat = 0
    @State private var outgoingOpacity: Double = 1
    @State private var incomingOffset: CGFloat = 0
    @State private var incomingOpacity: Double = 1

    var body: some View {
        Button {
            withAnimation(.smooth) {
                coordinator.currentView = provider.detailView
            }
            if vm.notchState == .closed {
                withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)) {
                    vm.open()
                }
            }
        } label: {
            badge
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(provider.displayName) quota"))
        .onChange(of: remainingPercent) { old, new in
            guard let old, let new, new < old else { return }
            playDropAnimation(from: old)
        }
    }

    private var badge: some View {
        ZStack {
            Circle().fill(provider.badgeFill)
            if let remainingPercent {
                ZStack {
                    if let outgoingValue {
                        Text("\(outgoingValue)")
                            .foregroundStyle(provider.badgeDigits)
                            .offset(y: outgoingOffset)
                            .opacity(outgoingOpacity)
                    }
                    Text("\(remainingPercent)")
                        .foregroundStyle(outgoingValue == nil ? provider.badgeDigits : provider.dropTint)
                        .offset(y: incomingOffset)
                        .opacity(incomingOpacity)
                }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                // Clip to the badge's full circle (so the ghost-slide digits
                // vanish at its edge) — not the text's own tight bounds, which
                // would shave the corners off the digits themselves.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(Circle())
            }
        }
        .frame(width: 19, height: 19)
    }

    private func playDropAnimation(from old: Int) {
        outgoingValue = old
        outgoingOffset = 0
        outgoingOpacity = 1
        incomingOffset = 6
        incomingOpacity = 0

        withAnimation(.easeIn(duration: 0.3)) {
            outgoingOffset = -8
            outgoingOpacity = 0
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85).delay(0.12)) {
            incomingOffset = 0
            incomingOpacity = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            outgoingValue = nil
        }
    }
}
