//
//  CodexQuotaMonitor.swift
//  boringNotch
//
//  Republishes the account's remaining "primary" weekly-quota percentage
//  for the closed-notch badge, read directly from Codex's own account
//  endpoint (the same one Codex Desktop queries for its usage display) —
//  see CodexAccountClient for the shared credential/request plumbing.
//  Read-only: this never writes or redeems anything on the account.
//
//  Previously this scanned the per-session cache files
//  ~/.codex/hooks/weekly_usage_footer.py maintains after each Codex CLI
//  turn, but that only reflects usage from CLI turns that actually ran
//  that hook — usage from Codex Desktop, or simply not having run a CLI
//  turn recently, left the badge showing a stale number. Querying the
//  account directly is accurate regardless of which client did the
//  spending.
//

import Foundation
import os

private let quotaLog = Logger(subsystem: "com.dynamicpeninsula.codexQuota", category: "monitor")

final class CodexQuotaMonitor: ObservableObject {
    static let shared = CodexQuotaMonitor()

    @Published private(set) var remainingPercent: Int?
    @Published private(set) var resetsAt: Date?
    /// The account's purchased Codex credits (`credits` in the same usage
    /// response). Read-only, like everything here.
    @Published private(set) var credits: Credits?

    struct Credits: Equatable {
        let balance: Double
        let unlimited: Bool
    }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private var pollTimer: Timer?

    private init() {
        start()
    }

    private func start() {
        Task { await refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        pollTimer?.tolerance = 15
    }

    func refresh() async {
        guard let json = await CodexAccountClient.fetchWithAutoRefresh(url: Self.usageURL),
              let rateLimit = json["rate_limit"] as? [String: Any],
              let primaryWindow = rateLimit["primary_window"] as? [String: Any],
              let usedPercent = primaryWindow["used_percent"] as? Int
        else {
            quotaLog.error("fetch failed or missing rate_limit.primary_window.used_percent")
            return
        }

        let remaining = max(0, min(100, 100 - usedPercent))
        let resetAt = (primaryWindow["reset_at"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        // balance has come back as a bare number; accept a numeric string
        // too, since that's how the other money-ish fields here are typed.
        let creditsJSON = json["credits"] as? [String: Any]
        let balance = (creditsJSON?["balance"] as? NSNumber)?.doubleValue
            ?? (creditsJSON?["balance"] as? String).flatMap(Double.init)
        let credits = balance.map { Credits(balance: $0, unlimited: creditsJSON?["unlimited"] as? Bool ?? false) }
        if credits == nil {
            quotaLog.error("missing or unrecognized credits.balance")
        }

        quotaLog.info("fetch ok, remaining=\(remaining, privacy: .public)")
        await publish(remainingPercent: remaining, resetsAt: resetAt, credits: credits)
    }

    @MainActor
    private func publish(remainingPercent: Int?, resetsAt: Date?, credits: Credits?) {
        quotaLog.info("publish: previous=\(self.remainingPercent ?? -1, privacy: .public) new=\(remainingPercent ?? -1, privacy: .public)")
        if let previous = self.remainingPercent, let new = remainingPercent, new < previous {
            quotaLog.info("publish: drop detected \(previous, privacy: .public) -> \(new, privacy: .public)")
            QuotaDropPresenter.shared.enqueue(provider: .codex, from: previous, to: new)
        }
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.credits = credits
    }
}
