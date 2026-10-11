//
//  AgentApprovalMonitor.swift
//  boringNotch
//
//  Standalone module: watches for the Codex CLI PermissionRequest hook
//  (~/.codex/hooks/notch_permission_request.py, registered in
//  ~/.codex/hooks.json) dropping a status file at
//  ~/.agentlight/codex/approval-status.json, and surfaces it as a
//  time-limited, read-only notice. Zero dependency on any other
//  boringNotch manager or on AgentBreathingMonitor.
//
//  This is deliberately informational only - there is no way to answer
//  a request from here. Codex fires PermissionRequest for every
//  approval-eligible action regardless of whether a human or the
//  built-in `auto_review` reviewer agent is the one actually deciding,
//  and there's currently no supported, documented way for an external
//  hook to tell those two cases apart (see
//  https://github.com/openai/codex/issues/23465, open/unresolved as of
//  this writing). A blocking hook that let the notch answer on the
//  user's behalf therefore couldn't distinguish "genuinely waiting on
//  you" from "auto_review would have resolved this instantly if left
//  alone" - which meant every auto_review-eligible action also
//  interrupted the user here. So the hook no longer blocks or waits for
//  a decision, and this monitor has nothing to send back: it just
//  reports that Codex asked for approval and lets Codex's own normal
//  flow (auto_review, or its native prompt) run untouched. Check the
//  Codex app itself for anything that actually needs a decision.
//

import Darwin
import Foundation
import SwiftUI

struct AgentApprovalNotice: Identifiable, Equatable {
    let id: String
    let toolName: String
    let command: String
    let cwd: String
    let createdAt: Date
}

final class AgentApprovalMonitor: ObservableObject {
    static let shared = AgentApprovalMonitor()

    /// The most recent PermissionRequest Codex fired, shown only as an FYI
    /// until it expires - see noticeLifetime. Never a request for the user
    /// to answer through this app.
    @Published private(set) var pendingRequest: AgentApprovalNotice?

    /// How long a notice stays visible before this monitor clears it on
    /// its own. There is no "resolved" signal to wait for anymore (the
    /// hook exits immediately instead of waiting on a response), so this
    /// is the only thing that ever dismisses a notice other than a newer
    /// one replacing it.
    private static let noticeLifetime: TimeInterval = 12

    /// See AgentBreathingMonitor for why this can't be
    /// FileManager.default.homeDirectoryForCurrentUser under App Sandbox.
    private static var realHomeDirectory: URL {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir))
    }

    private let channelDirectory = AgentApprovalMonitor.realHomeDirectory
        .appendingPathComponent(".agentlight")
        .appendingPathComponent("codex")

    private var statusURL: URL { channelDirectory.appendingPathComponent("approval-status.json") }

    private let queue = DispatchQueue(label: "boringNotch.AgentApprovalMonitor")
    private var directorySource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var expiryTimer: Timer?
    private var lastPublishedID: String?

    private init() {
        start()
    }

    private func start() {
        try? FileManager.default.createDirectory(at: channelDirectory, withIntermediateDirectories: true)
        readAndPublish()
        startDirectoryMonitor()
        // Backstop for the rare case the DispatchSource misses an event —
        // the DispatchSource is what actually delivers near-instant
        // detection; this is only insurance.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.queue.async { self?.readAndPublish() }
        }
        pollTimer?.tolerance = 0.5
    }

    private func startDirectoryMonitor() {
        let descriptor = open(channelDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.readAndPublish()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directorySource = source
        source.resume()
    }

    private func readAndPublish() {
        guard let data = try? Data(contentsOf: statusURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String
        else {
            return
        }

        guard id != lastPublishedID else { return }
        lastPublishedID = id

        let createdAt: Date
        if let epoch = json["created_at"] as? Double {
            createdAt = Date(timeIntervalSince1970: epoch)
        } else {
            createdAt = Date()
        }

        // A status file left over from before a restart, or one this
        // monitor was slow to pick up, shouldn't pop up looking fresh.
        let age = Date().timeIntervalSince(createdAt)
        guard age >= 0, age < Self.noticeLifetime else { return }

        let notice = AgentApprovalNotice(
            id: id,
            toolName: json["tool_name"] as? String ?? "Tool",
            command: json["command"] as? String ?? "",
            cwd: json["cwd"] as? String ?? "",
            createdAt: createdAt
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRequest = notice
            self.scheduleExpiry(for: notice)
        }
    }

    /// Clears the notice on its own after noticeLifetime, since nothing
    /// ever tells this monitor the request was resolved.
    private func scheduleExpiry(for notice: AgentApprovalNotice) {
        expiryTimer?.invalidate()
        let remaining = max(0, Self.noticeLifetime - Date().timeIntervalSince(notice.createdAt))
        expiryTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.pendingRequest?.id == notice.id {
                self.pendingRequest = nil
            }
        }
    }
}
