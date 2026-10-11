//
//  QuotaDropRevealView.swift
//  boringNotch
//
//  The content shown inside ContentView's quotaDropRevealPill: the
//  agent's logo and a small caption, plus the ghost-slide digit swap (old
//  value slides up and fades, new value — tinted per agent — rises in
//  from below), the same mechanic as QuotaBadgeView's tiny in-place
//  version, just at a size that actually does it justice. Picked from a
//  set of HTML mockups.
//

import SwiftUI

struct QuotaDropRevealView: View {
    let drop: QuotaDropPresenter.Drop
    /// How much empty space to leave above the label/number — has to clear
    /// the physical camera cutout, which sits at the very top of this pill
    /// just like it does over the normal closed-notch row.
    let topInset: CGFloat

    @State private var oldOffset: CGFloat = 0
    @State private var oldOpacity: Double = 1
    @State private var newOffset: CGFloat = 14
    @State private var newOpacity: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                drop.provider.logo
                    .frame(width: 10, height: 10)
                Text("\(drop.provider.displayName.uppercased()) WEEKLY")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.4))
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                ZStack {
                    Text("\(drop.from)")
                        .foregroundStyle(.white)
                        .offset(y: oldOffset)
                        .opacity(oldOpacity)
                    Text("\(drop.to)")
                        .foregroundStyle(drop.provider.dropTint)
                        .offset(y: newOffset)
                        .opacity(newOpacity)
                }
                Text("%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .font(.system(size: 30, weight: .bold, design: .rounded))
        }
        .padding(.top, topInset + 4)
        .onAppear { playSlide() }
    }

    private func playSlide() {
        withAnimation(.easeIn(duration: 0.32)) {
            oldOffset = -14
            oldOpacity = 0
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.14)) {
            newOffset = 0
            newOpacity = 1
        }
    }
}
