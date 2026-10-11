//
//  AgentTabView.swift
//  boringNotch
//
//  The Codex tab (opened by the left quota badge): shows a pending Codex
//  approval request (see AgentApprovalMonitor) when there is one,
//  otherwise Codex's live status, a 30-day token-usage chart
//  (CodexUsageStatsService), the weekly quota as a bar with its reset
//  countdown (CodexQuotaMonitor), and the account's free reset credits
//  and purchased credit balance. All sized to fit the same 123pt-tall slot
//  every other module in this position uses. The Claude counterpart is
//  ClaudeTabView; the building blocks both share (AgentStatusRow,
//  DailyTokenChart, QuotaWindowBar, AgentFootnote) live here.
//

import SwiftUI

struct AgentTabView: View {
    @ObservedObject private var approvalMonitor = AgentApprovalMonitor.shared
    @ObservedObject private var breathingMonitor = AgentBreathingMonitor.codex
    @ObservedObject private var quotaMonitor = CodexQuotaMonitor.shared
    @ObservedObject private var usageStats = CodexUsageStatsService.shared
    @ObservedObject private var resetCreditsMonitor = CodexResetCreditsMonitor.shared

    var body: some View {
        Group {
            if let request = approvalMonitor.pendingRequest {
                ApprovalRequestCardView(request: request)
            } else {
                idleContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 123)
        .padding(.horizontal, 4)
        .onAppear {
            usageStats.refreshIfNeeded()
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentStatusRow(provider: .codex, state: breathingMonitor.state)
            DailyTokenChart(days: usageStats.dailyUsage, tint: QuotaProvider.codex.badgeFill)
            QuotaWindowBar(
                title: "WEEKLY",
                remainingPercent: quotaMonitor.remainingPercent,
                resetsAt: quotaMonitor.resetsAt,
                tint: QuotaProvider.codex.badgeFill
            )
            HStack(spacing: 14) {
                // Purely informational — read-only, no reset button.
                // Deliberate: this app never redeems a reset credit, only
                // shows how many the account has (see CodexResetCreditsMonitor).
                if let count = resetCreditsMonitor.availableCount {
                    AgentFootnote(
                        icon: "gift.fill",
                        text: resetCreditsLabel(count: count, expiresAt: resetCreditsMonitor.nextCredit?.expiresAt)
                    )
                }
                if let credits = quotaMonitor.credits {
                    AgentFootnote(
                        icon: "creditcard.fill",
                        text: credits.unlimited ? "Credits unlimited" : "Credits \(credits.balance.formatted())"
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 2)
    }
}

struct AgentStatusRow: View {
    let provider: QuotaProvider
    let state: AgentBreathingState

    var body: some View {
        HStack(spacing: 8) {
            provider.logo
                .frame(width: 13, height: 13)
            Text(provider.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Circle()
                .fill(state.color)
                .frame(width: 6, height: 6)
            Text(state.rawValue.capitalized)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 0)
        }
    }
}

struct DailyTokenChart: View {
    let days: [DailyTokenUsage]
    let tint: Color

    @State private var hoveredDay: DailyTokenUsage?

    private static let barAreaHeight: CGFloat = 32

    var body: some View {
        let maxTokens = max(days.map(\.tokens).max() ?? 0, 1)

        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("TOKENS · LAST 30 DAYS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .tracking(0.5)
                Spacer(minLength: 0)
                // Hovering a bar swaps this for that day's own reading;
                // otherwise it's just the 30-day peak.
                if let hoveredDay {
                    Text("\(dayLabel(hoveredDay.date)) · \(formatTokens(hoveredDay.tokens))")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                } else if maxTokens > 1 {
                    Text(formatTokens(maxTokens))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            // Fixed per-bar height (not idealHeight) — idealHeight gets
            // silently overridden back to the container's full height by
            // maxHeight: .infinity on a sibling-stretched HStack, which is
            // why every bar rendered the same height before.
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { day in
                    VStack {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(barColor(for: day))
                            .frame(height: max(3, CGFloat(day.tokens) / CGFloat(maxTokens) * Self.barAreaHeight))
                    }
                    // The full-height column (not just the short bar itself)
                    // is the hover target, so a near-empty day is just as
                    // easy to point at as a tall one.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        hoveredDay = isHovering ? day : (hoveredDay?.id == day.id ? nil : hoveredDay)
                    }
                }
            }
            .frame(height: Self.barAreaHeight, alignment: .bottom)
        }
    }

    private func barColor(for day: DailyTokenUsage) -> Color {
        if hoveredDay?.id == day.id { return tint }
        return tint.opacity(day.tokens > 0 ? 0.85 : 0.15)
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.0fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.0fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}

/// One usage-limit window: "WEEKLY  82% left · resets in 5d 23h" over a
/// thin bar filled to the remaining share.
struct QuotaWindowBar: View {
    let title: String
    let remainingPercent: Int?
    /// nil either because it's unknown or because the window hasn't started
    /// yet — only shown when there's a percentage to go with it.
    let resetsAt: Date?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer(minLength: 0)
                if let remainingPercent {
                    Text("\(remainingPercent)% left")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(resetsAt.map { "· resets in \(quotaCountdown(to: $0))" } ?? "· not started")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    Text("—")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * CGFloat(remainingPercent ?? 0) / 100)
                }
            }
            .frame(height: 5)
        }
    }
}

struct AgentFootnote: View {
    let icon: String
    let text: String
    var color: Color = .white.opacity(0.55)

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

func resetCreditsLabel(count: Int, expiresAt: Date?) -> String {
    let plural = count == 1 ? "reset credit" : "reset credits"
    guard count > 0, let expiresAt else {
        return "\(count) \(plural)"
    }
    return "\(count) \(plural) · expires in \(quotaCountdown(to: expiresAt))"
}

func quotaCountdown(to date: Date) -> String {
    let interval = max(0, date.timeIntervalSinceNow)
    let days = Int(interval) / 86400
    let hours = (Int(interval) % 86400) / 3600
    if days > 0 {
        return "\(days)d \(hours)h"
    }
    let minutes = (Int(interval) % 3600) / 60
    return "\(hours)h \(minutes)m"
}
