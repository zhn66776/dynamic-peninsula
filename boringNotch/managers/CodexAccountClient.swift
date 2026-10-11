//
//  CodexAccountClient.swift
//  boringNotch
//
//  Shared low-level plumbing for the Codex-account-reading monitors
//  (CodexQuotaMonitor, CodexResetCreditsMonitor): loading OAuth credentials
//  from ~/.codex/auth.json and making an authenticated GET against
//  chatgpt.com's private backend-api, refreshing a stale access token in
//  memory and retrying once before giving up. Strictly read-only — nothing
//  here ever calls an endpoint that writes or redeems anything on the
//  account (in particular, never account/rateLimitResetCredit/consume).
//
//  The access token is refreshed in memory only and never written back to
//  auth.json, so a bug here can't corrupt the user's actual Codex
//  CLI/Desktop login state.
//

import Darwin
import Foundation

struct CodexOAuthCredentials {
    let accessToken: String
    let refreshToken: String
    let accountId: String?
}

enum CodexAccountClient {
    private static let refreshTokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    // The OAuth client id Codex CLI itself uses for its refresh-token grant
    // (see codex-rs/login/src/auth/manager.rs upstream) — this identifies
    // the client application to the token endpoint, it isn't a per-user
    // secret.
    private static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    // Foundation's homeDirectoryForCurrentUser is virtualized under App
    // Sandbox (resolves to this app's own container), so it can never reach
    // ~/.codex/auth.json regardless of file-access entitlements — same fix
    // as every other manager here that reads outside the container.
    private static var realHomeDirectory: URL {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir))
    }

    private static let authFileURL = realHomeDirectory
        .appendingPathComponent(".codex")
        .appendingPathComponent("auth.json")

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    static func readCredentials() -> CodexOAuthCredentials? {
        guard let data = try? Data(contentsOf: authFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String
        else { return nil }
        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountId: tokens["account_id"] as? String
        )
    }

    static func refreshAccessToken(refreshToken: String) async -> String? {
        var request = URLRequest(url: refreshTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": oauthClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else { return nil }
        return accessToken
    }

    /// GETs `url` with the given bearer token/account id. Returns the
    /// decoded JSON object on any 2xx response, nil otherwise — the caller
    /// decides whether that's worth a refresh-and-retry.
    static func authorizedGet(
        url: URL,
        accessToken: String,
        accountId: String?,
        extraHeaders: [String: String] = [:]
    ) async -> [String: Any]? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("boringNotch", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Fetches `url` using the account's cached access token, refreshing it
    /// once in memory and retrying if the first attempt fails — covers the
    /// common case where the cached token simply went stale since Codex
    /// CLI/Desktop last ran. Returns nil (not a thrown error) on any
    /// failure so callers can just keep their last-known-good value.
    static func fetchWithAutoRefresh(
        url: URL,
        extraHeaders: [String: String] = [:]
    ) async -> [String: Any]? {
        guard let credentials = readCredentials() else { return nil }

        if let json = await authorizedGet(
            url: url,
            accessToken: credentials.accessToken,
            accountId: credentials.accountId,
            extraHeaders: extraHeaders)
        {
            return json
        }

        guard let refreshedToken = await refreshAccessToken(refreshToken: credentials.refreshToken) else {
            return nil
        }
        return await authorizedGet(
            url: url,
            accessToken: refreshedToken,
            accountId: credentials.accountId,
            extraHeaders: extraHeaders)
    }
}
