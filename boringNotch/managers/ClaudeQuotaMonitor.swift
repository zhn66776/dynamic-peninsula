//
//  ClaudeQuotaMonitor.swift
//  boringNotch
//
//  Claude's 5-hour and weekly usage limits, read from the same claude.ai
//  endpoint the web app's Settings → Usage page draws from
//  (/api/organizations/{uuid}/usage). There's no public API for a
//  subscription's usage, and the Claude desktop app keeps its own login to
//  itself, so this authenticates with a claude.ai `sessionKey` cookie the
//  user pastes into Settings once (stored in this app's own Keychain item,
//  see ClaudeSessionKeyStore). That cookie expires eventually; when it
//  does, `lastError` says so and the last good numbers stay on screen.
//  Read-only: only ever GETs.
//
//  The badge (and the drop reveal) track the *weekly* window, same as
//  Codex's; the 5-hour window and the account's usage-credit balance
//  (`spend` — the pay-as-you-go credits that kick in past the plan's
//  limits) show in the Claude tab, as do free usage-limit reset credits
//  once claude.ai exposes them — see resetCreditsPath.
//

import Foundation
import os
import Security
import LocalAuthentication

private let claudeQuotaLog = Logger(subsystem: "com.dynamicpeninsula.claudeQuota", category: "monitor")

enum ClaudeSessionKeyStore {
    private static let service = "\(Bundle.main.bundleIdentifier!).claudeSessionKey"

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    static func read() throws -> String? {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: authentication
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ sessionKey: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError(status: deleteStatus)
        }
        var attributes = query
        attributes[kSecValueData] = Data(sessionKey.utf8)
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }
}

@MainActor
final class ClaudeQuotaMonitor: ObservableObject {
    static let shared = ClaudeQuotaMonitor()

    struct Window: Equatable {
        let remainingPercent: Int
        /// nil while the window hasn't started yet (nothing used in it).
        let resetsAt: Date?
    }

    struct Money: Equatable {
        let amountMinor: Int
        let currency: String
        let exponent: Int

        var formatted: String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            formatter.maximumFractionDigits = exponent
            formatter.minimumFractionDigits = exponent
            let major = Double(amountMinor) / pow(10, Double(exponent))
            return formatter.string(from: major as NSNumber)!
        }
    }

    struct UsageCredits: Equatable {
        /// nil when the account holds no credits at all (claude.ai then
        /// reports disabledReason "out_of_credits").
        let balance: Money?
        let enabled: Bool
        let disabledReason: String?
    }

    enum FetchError: LocalizedError {
        case noSessionKey
        case http(Int)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .noSessionKey:
                return "No claude.ai session key — add one in Settings"
            case .http(let status) where status == 401 || status == 403:
                return "claude.ai rejected the session key (HTTP \(status)) — it has probably expired, paste a new one in Settings"
            case .http(let status):
                return "claude.ai returned HTTP \(status)"
            case .malformed(let detail):
                return "Unexpected claude.ai response: \(detail)"
            }
        }
    }

    @Published private(set) var fiveHour: Window?
    @Published private(set) var weekly: Window?
    @Published private(set) var usageCredits: UsageCredits?
    @Published private(set) var resetCredits: ResetCredits?

    struct ResetCredits: Equatable {
        let availableCount: Int
        let nextExpiresAt: Date?
    }

    /// Claude's free usage-limit reset credits — off (nil) until claude.ai
    /// exposes an endpoint for them. To turn it on, set this to that
    /// endpoint's path under /api/organizations/{uuid}/; the Claude tab
    /// shows the row as soon as `resetCredits` is non-nil. parseResetCredits
    /// assumes the same shape as Codex's /wham/rate-limit-reset-credits and
    /// may need adjusting to the real one. Read-only either way: this only
    /// ever GETs, never redeems a credit.
    private static let resetCreditsPath: String? = nil
    @Published private(set) var lastError: String?

    private static let baseURL = URL(string: "https://claude.ai/api")!
    // claude.ai sits behind Cloudflare, which is far more likely to let a
    // browser-shaped request through than URLSession's default agent.
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        // The Cookie header is set by hand; don't let a stored cookie
        // override it.
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    private var organizationID: String?
    private var pollTimer: Timer?

    private init() {
        Task { await refresh() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        pollTimer?.tolerance = 15
    }

    /// Accepts either the bare cookie value or a pasted `sessionKey=…`.
    func updateSessionKey(_ raw: String) async {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("sessionKey=") { key.removeFirst("sessionKey=".count) }
        do {
            try ClaudeSessionKeyStore.save(key)
        } catch {
            lastError = error.localizedDescription
            return
        }
        organizationID = nil
        await refresh()
    }

    func refresh() async {
        do {
            guard let sessionKey = try ClaudeSessionKeyStore.read() else { throw FetchError.noSessionKey }
            let orgID = try await resolveOrganizationID(sessionKey: sessionKey)
            let usage = try await get(path: "organizations/\(orgID)/usage", sessionKey: sessionKey)
            guard let usage = usage as? [String: Any] else { throw FetchError.malformed("usage is not an object") }
            guard let weekly = Self.parseWindow(usage["seven_day"]) else { throw FetchError.malformed("missing seven_day") }
            var resetCredits: ResetCredits?
            if let path = Self.resetCreditsPath {
                resetCredits = try Self.parseResetCredits(
                    await get(path: "organizations/\(orgID)/\(path)", sessionKey: sessionKey))
            }
            publish(
                fiveHour: Self.parseWindow(usage["five_hour"]),
                weekly: weekly,
                usageCredits: try Self.parseUsageCredits(usage["spend"]),
                resetCredits: resetCredits
            )
        } catch {
            claudeQuotaLog.error("refresh failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    private func resolveOrganizationID(sessionKey: String) async throws -> String {
        if let organizationID { return organizationID }
        guard let orgs = try await get(path: "organizations", sessionKey: sessionKey) as? [[String: Any]] else {
            throw FetchError.malformed("organizations is not an array")
        }
        // The personal claude.ai org is the one with the "chat" capability;
        // an account can also belong to API-only orgs, which have no
        // subscription usage.
        guard let chatOrg = orgs.first(where: { ($0["capabilities"] as? [String])?.contains("chat") == true }),
              let uuid = chatOrg["uuid"] as? String
        else { throw FetchError.malformed("no organization with chat capability") }
        organizationID = uuid
        return uuid
    }

    private func get(path: String, sessionKey: String) async throws -> Any {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")

        let (data, response) = try await session.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard (200...299).contains(status) else { throw FetchError.http(status) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// `{"utilization": 37.0, "resets_at": "2026-09-30T08:00:00.123456+00:00"}`
    /// — utilization is percent *used*.
    private static func parseWindow(_ raw: Any?) -> Window? {
        guard let dict = raw as? [String: Any], let utilization = dict["utilization"] as? Double else { return nil }
        let remaining = max(0, min(100, 100 - Int(utilization.rounded())))
        return Window(remainingPercent: remaining, resetsAt: parseDate(dict["resets_at"] as? String))
    }

    /// `{"enabled": false, "balance": null, "disabled_reason": "out_of_credits",
    /// "used": {"amount_minor": 0, "currency": "GBP", "exponent": 2}, …}`.
    /// Only a null balance has been seen so far; a non-null one is assumed
    /// to be shaped like `used`, and anything else is reported rather than
    /// guessed at.
    private static func parseUsageCredits(_ raw: Any?) throws -> UsageCredits? {
        guard let spend = raw as? [String: Any] else { return nil }
        let balance: Money?
        switch spend["balance"] {
        case nil, is NSNull:
            balance = nil
        case let money as [String: Any]:
            guard let parsed = parseMoney(money) else { throw FetchError.malformed("spend.balance \(money)") }
            balance = parsed
        case let other?:
            throw FetchError.malformed("spend.balance \(other)")
        }
        return UsageCredits(
            balance: balance,
            enabled: spend["enabled"] as? Bool ?? false,
            disabledReason: spend["disabled_reason"] as? String
        )
    }

    /// Assumed shape (Codex's): `{"available_count": 1, "credits":
    /// [{"status": "available", "expires_at": "2026-10-22T…Z"}, …]}`.
    private static func parseResetCredits(_ raw: Any) throws -> ResetCredits {
        guard let json = raw as? [String: Any], let count = json["available_count"] as? Int else {
            throw FetchError.malformed("reset credits \(raw)")
        }
        let expiries = ((json["credits"] as? [[String: Any]]) ?? [])
            .filter { $0["status"] as? String == "available" }
            .compactMap { parseDate($0["expires_at"] as? String) }
        return ResetCredits(availableCount: count, nextExpiresAt: expiries.min())
    }

    private static func parseMoney(_ raw: [String: Any]) -> Money? {
        guard let amountMinor = raw["amount_minor"] as? Int,
              let currency = raw["currency"] as? String,
              let exponent = raw["exponent"] as? Int
        else { return nil }
        return Money(amountMinor: amountMinor, currency: currency, exponent: exponent)
    }

    /// resets_at carries microseconds, which ISO8601DateFormatter's
    /// fractional-seconds option doesn't reliably accept — whole seconds
    /// are plenty for a countdown, so drop the fraction.
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let wholeSeconds = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: wholeSeconds)
    }

    private func publish(fiveHour: Window?, weekly: Window, usageCredits: UsageCredits?, resetCredits: ResetCredits?) {
        claudeQuotaLog.info("fetch ok, 5h=\(fiveHour?.remainingPercent ?? -1, privacy: .public) weekly=\(weekly.remainingPercent, privacy: .public)")
        if let previous = self.weekly?.remainingPercent, weekly.remainingPercent < previous {
            QuotaDropPresenter.shared.enqueue(provider: .claude, from: previous, to: weekly.remainingPercent)
        }
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.usageCredits = usageCredits
        self.resetCredits = resetCredits
        lastError = nil
    }
}
