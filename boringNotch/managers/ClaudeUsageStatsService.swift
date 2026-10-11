//
//  ClaudeUsageStatsService.swift
//  boringNotch
//
//  Claude's counterpart to CodexUsageStatsService: a 30-day daily-token
//  chart for the Claude tab, built from Claude Code's own session
//  transcripts (~/.claude/projects/**/*.jsonl — the desktop app's Code tab
//  writes them too, subagent transcripts included). Every assistant line
//  carries that API response's `message.usage`; "tokens" here is
//  input + cache-creation + cache-read + output, the same everything-in
//  total Codex's total_tokens reports, so the two charts are comparable.
//
//  Two wrinkles:
//  - One API response is written as several lines (one per content
//    block), each repeating the same message id and usage, so usage is
//    keyed by message id — which also dedupes a response copied into a
//    second transcript by a resumed/forked session.
//  - Unlike Codex's rollouts there's no running total to tail for, so each
//    transcript is read in full. To keep the 5-minute refresh cheap, each
//    file's parsed result is cached by (mtime, size) and only files that
//    actually changed get re-read.
//

import Darwin
import Foundation
import os

private let claudeUsageLog = Logger(subsystem: "com.dynamicpeninsula.claudeUsage", category: "stats")

final class ClaudeUsageStatsService: ObservableObject {
    static let shared = ClaudeUsageStatsService()

    @Published private(set) var dailyUsage: [DailyTokenUsage] = []

    private struct FileSignature: Equatable {
        let modified: Date
        let size: Int
    }

    private struct ParsedFile {
        let signature: FileSignature
        /// message id → (day key, tokens)
        let messages: [String: (day: String, tokens: Int)]
    }

    private static var realHomeDirectory: URL {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir))
    }

    private let projectsDirectory = ClaudeUsageStatsService.realHomeDirectory
        .appendingPathComponent(".claude")
        .appendingPathComponent("projects")

    private let queue = DispatchQueue(label: "boringNotch.ClaudeUsageStatsService", qos: .utility)
    private var isRefreshing = false
    private var lastRefreshAt = Date.distantPast
    private let refreshInterval: TimeInterval = 300
    private let windowDays = 30
    private var cache: [URL: ParsedFile] = [:]

    private init() {}

    /// Cheap to call from onAppear — coalesces overlapping calls and calls
    /// within refreshInterval of the last real scan.
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

    private func scan() -> [DailyTokenUsage] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today)!

        let enumerator = FileManager.default.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) { url, error in
            claudeUsageLog.error("enumerating \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return true
        }!

        var liveCache: [URL: ParsedFile] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try! url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let signature = FileSignature(modified: values.contentModificationDate!, size: values.fileSize!)
            // A transcript last touched before the window can't hold any
            // message inside it.
            guard signature.modified >= windowStart else { continue }
            if let cached = cache[url], cached.signature == signature {
                liveCache[url] = cached
            } else {
                liveCache[url] = ParsedFile(signature: signature, messages: parseMessages(in: url))
            }
        }
        cache = liveCache

        var byMessage: [String: (day: String, tokens: Int)] = [:]
        for parsed in liveCache.values {
            byMessage.merge(parsed.messages) { existing, _ in existing }
        }
        var totals: [String: Int] = [:]
        for entry in byMessage.values {
            totals[entry.day, default: 0] += entry.tokens
        }

        return (0..<windowDays).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let key = Self.dayKeyFormatter.string(from: date)
            return DailyTokenUsage(id: key, date: date, tokens: totals[key] ?? 0)
        }
    }

    private static let usageMarker = Data(#""usage""#.utf8)

    private func parseMessages(in url: URL) -> [String: (day: String, tokens: Int)] {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch CocoaError.fileReadNoSuchFile {
            // Deleted between enumeration and read.
            return [:]
        } catch {
            claudeUsageLog.error("reading \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }

        var messages: [String: (day: String, tokens: Int)] = [:]
        for line in data.split(separator: 0x0A) {
            // Only assistant lines carry usage — skip JSON-decoding the rest
            // (tool results, user turns), which are most of the bytes.
            guard line.range(of: Self.usageMarker) != nil,
                  let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let id = message["id"] as? String,
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = json["timestamp"] as? String,
                  let date = Self.timestampFormatter.date(from: timestamp)
            else { continue }

            let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
            messages[id] = (Self.dayKeyFormatter.string(from: date), tokens)
        }
        return messages
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
