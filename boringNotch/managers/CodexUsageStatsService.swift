//
//  CodexUsageStatsService.swift
//  boringNotch
//
//  Standalone module: builds a rough daily-token-usage chart for the Agent
//  tab straight from Codex's own rollout logs
//  (~/.codex/sessions/**/*.jsonl) — no extra hook or cache file needed,
//  those logs already carry a cumulative token_count event per turn.
//
//  Reading every rollout file in full isn't an option — the last 30 days
//  alone run well over a gigabyte on an active account. Instead this only
//  tails the last ~64KB of each file (bounded, fast) to find that
//  session's *last* token_count event, whose total_token_usage.total_tokens
//  is already the session's running total — summed per calendar day across
//  sessions. That slightly over/under-attributes a session that happens to
//  straddle midnight, which is an acceptable trade for not reading
//  gigabytes of transcript just to draw a bar chart.
//

import Darwin
import Foundation

struct DailyTokenUsage: Identifiable {
    let id: String
    let date: Date
    let tokens: Int
}

final class CodexUsageStatsService: ObservableObject {
    static let shared = CodexUsageStatsService()

    @Published private(set) var dailyUsage: [DailyTokenUsage] = []

    private static var realHomeDirectory: URL {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir))
    }

    private let sessionsDirectory = CodexUsageStatsService.realHomeDirectory
        .appendingPathComponent(".codex")
        .appendingPathComponent("sessions")

    private let queue = DispatchQueue(label: "boringNotch.CodexUsageStatsService", qos: .utility)
    private var isRefreshing = false
    private var lastRefreshAt = Date.distantPast
    private let refreshInterval: TimeInterval = 300
    private let windowDays = 30
    private let tailBytes: UInt64 = 65536

    private init() {}

    /// Cheap to call from onAppear — coalesces both overlapping calls and
    /// calls that land well within refreshInterval of the last real scan.
    func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastRefreshAt) > refreshInterval else { return }
        refresh()
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self, !self.isRefreshing else { return }
            self.isRefreshing = true
            self.lastRefreshAt = Date()
            let result = self.scan()
            self.isRefreshing = false
            DispatchQueue.main.async { [weak self] in
                self?.dailyUsage = result
            }
        }
    }

    /// Targets exactly the windowDays day-folders (~/.codex/sessions/YYYY/MM/DD/)
    /// this needs, instead of a recursive enumerator over the whole
    /// sessions tree. An account with months of history has hundreds of
    /// files outside the window; walking every one of them just to check
    /// its mtime and discard it is pure waste when the folder layout
    /// already encodes the date — this touches only the ~30 folders that
    /// can possibly matter.
    private func scan() -> [DailyTokenUsage] {
        let fileManager = FileManager.default
        let calendar = Calendar.current
        let dayFormatter = Self.dayKeyFormatter
        let today = calendar.startOfDay(for: Date())

        var totals: [String: Int] = [:]
        var result: [DailyTokenUsage] = []

        for offset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = dayFormatter.string(from: date)
            result.append(DailyTokenUsage(id: key, date: date, tokens: 0))

            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let dayOfMonth = components.day else { continue }
            let dayDirectory = sessionsDirectory
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", dayOfMonth))

            guard let entries = try? fileManager.contentsOfDirectory(
                at: dayDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries where url.pathExtension == "jsonl" {
                guard let (tokenDay, tokens) = lastTokenCount(in: url) else { continue }
                totals[tokenDay, default: 0] += tokens
            }
        }

        return result.map { DailyTokenUsage(id: $0.id, date: $0.date, tokens: totals[$0.id] ?? 0) }
    }

    private func lastTokenCount(in url: URL) -> (day: String, tokens: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }
        let offset = fileSize > tailBytes ? fileSize - tailBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }

        var lastDay: String?
        var lastTokens: Int?

        for lineData in data.split(separator: 0x0A) {
            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] as? [String: Any],
                  let tokens = totalUsage["total_tokens"] as? Int,
                  let timestampString = json["timestamp"] as? String,
                  let date = Self.timestampFormatter.date(from: timestampString)
            else { continue }

            lastDay = Self.dayKeyFormatter.string(from: date)
            lastTokens = tokens
        }

        guard let day = lastDay, let tokens = lastTokens else { return nil }
        return (day, tokens)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}
