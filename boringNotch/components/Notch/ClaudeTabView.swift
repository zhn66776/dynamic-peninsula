//
//  ClaudeTabView.swift
//  boringNotch
//
//  The Claude tab (opened by the right quota badge), laid out like the
//  Codex tab: Claude's live status (AgentBreathingMonitor.claude), a
//  30-day token-usage chart (ClaudeUsageStatsService), the 5-hour and
//  weekly limits side by side with their reset countdowns, and the
//  account's usage-credit balance (ClaudeQuotaMonitor), plus free reset
//  credits once ClaudeQuotaMonitor.resetCreditsPath is turned on. Same
//  123pt-tall slot as AgentTabView.
//

import SwiftUI

struct ClaudeTabView: View {
    @ObservedObject private var breathingMonitor = AgentBreathingMonitor.claude
    @ObservedObject private var quotaMonitor = ClaudeQuotaMonitor.shared
    @ObservedObject private var usageStats = ClaudeUsageStatsService.shared

    private let tint = QuotaProvider.claude.badgeFill

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentStatusRow(provider: .claude, state: breathingMonitor.state)
            DailyTokenChart(days: usageStats.dailyUsage, tint: tint)
            HStack(spacing: 14) {
                QuotaWindowBar(
                    title: "5-HOUR",
                    remainingPercent: quotaMonitor.fiveHour?.remainingPercent,
                    resetsAt: quotaMonitor.fiveHour?.resetsAt,
                    tint: tint
                )
                QuotaWindowBar(
                    title: "WEEKLY",
                    remainingPercent: quotaMonitor.weekly?.remainingPercent,
                    resetsAt: quotaMonitor.weekly?.resetsAt,
                    tint: tint
                )
            }
            HStack(spacing: 14) {
                if let lastError = quotaMonitor.lastError {
                    AgentFootnote(
                        icon: "exclamationmark.triangle.fill",
                        text: lastError,
                        color: Color(red: 1.00, green: 0.55, blue: 0.45)
                    )
                } else {
                    if let resetCredits = quotaMonitor.resetCredits {
                        AgentFootnote(
                            icon: "gift.fill",
                            text: resetCreditsLabel(count: resetCredits.availableCount, expiresAt: resetCredits.nextExpiresAt)
                        )
                    }
                    if let credits = quotaMonitor.usageCredits {
                        AgentFootnote(icon: "creditcard.fill", text: usageCreditsLabel(credits))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: 123, alignment: .topLeading)
        .padding(.horizontal, 4)
        .onAppear {
            usageStats.refreshIfNeeded()
        }
    }

    private func usageCreditsLabel(_ credits: ClaudeQuotaMonitor.UsageCredits) -> String {
        let balance = credits.balance?.formatted ?? "none"
        return "Usage credits \(balance)\(credits.enabled ? "" : " · off")"
    }
}
