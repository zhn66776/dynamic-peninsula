//
//  CodexResetCreditsMonitor.swift
//  boringNotch
//
//  Read-only lookup of the account's available "rate limit reset" credits —
//  free resets OpenAI occasionally grants that instantly clear the current
//  weekly rate-limit window when redeemed. This monitor only ever calls the
//  read endpoint (the same one Codex Desktop itself queries to draw its own
//  credits UI) and never touches account/rateLimitResetCredit/consume or any
//  other endpoint that could redeem a credit — that is a deliberate, permanent
//  limitation of this file, not an oversight to "finish later".
//
//  Credential loading and the authenticated-GET-with-retry plumbing live in
//  CodexAccountClient, shared with CodexQuotaMonitor.
//

import Foundation
import os

// Temporary diagnostic logging while this feature is being verified against
// a real account — view with e.g.
// `log stream --predicate 'subsystem == "com.dynamicpeninsula.codexResetCredits"'`.
// Deliberately no sensitive values (tokens, full response bodies) are logged.
private let resetCreditsLog = Logger(subsystem: "com.dynamicpeninsula.codexResetCredits", category: "monitor")

struct CodexResetCredit: Equatable {
    let status: String
    let title: String?
    let description: String?
    let expiresAt: Date?
}

final class CodexResetCreditsMonitor: ObservableObject {
    static let shared = CodexResetCreditsMonitor()

    @Published private(set) var availableCount: Int?
    @Published private(set) var nextCredit: CodexResetCredit?

    private static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    // These two headers match what Codex Desktop itself sends to this
    // endpoint — it isn't publicly documented, so the request shape has to
    // mirror the real client's rather than a generic API call.
    private static let extraHeaders = [
        "OpenAI-Beta": "codex-1",
        "originator": "Codex Desktop"
    ]

    private var pollTimer: Timer?

    private init() {
        Task { await self.refresh() }
        // Reset credits are granted rarely (nothing like the per-turn
        // cadence the quota badge tracks), so a slow poll is plenty and
        // keeps this feature's own network chatter to a handful of
        // requests an hour.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        pollTimer?.tolerance = 30
    }

    func refresh() async {
        guard let json = await CodexAccountClient.fetchWithAutoRefresh(
            url: Self.resetCreditsURL,
            extraHeaders: Self.extraHeaders),
            let availableCount = json["available_count"] as? Int
        else {
            resetCreditsLog.error("fetch failed or missing available_count")
            return
        }

        let creditsArray = (json["credits"] as? [[String: Any]]) ?? []
        let credits = creditsArray.compactMap { entry -> CodexResetCredit? in
            guard let status = entry["status"] as? String else { return nil }
            return CodexResetCredit(
                status: status,
                title: entry["title"] as? String,
                description: entry["description"] as? String,
                expiresAt: Self.parseISO8601(entry["expires_at"] as? String)
            )
        }

        resetCreditsLog.info("fetch ok, availableCount=\(availableCount, privacy: .public)")
        await publish(availableCount: availableCount, credit: credits.first { $0.status == "available" })
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: raw)
    }

    @MainActor
    private func publish(availableCount: Int?, credit: CodexResetCredit?) {
        self.availableCount = availableCount
        self.nextCredit = credit
    }
}
