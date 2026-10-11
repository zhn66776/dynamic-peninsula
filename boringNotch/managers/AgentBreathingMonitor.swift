//
//  AgentBreathingMonitor.swift
//  boringNotch
//
//  Standalone module: watches an agent's breathing-light state file
//  (~/.agentlight/<channel>/state, written by the agentlight-set.sh hook —
//  "codex" from ~/.codex/hooks.json, "claude" from ~/.claude/settings.json)
//  and republishes it as a SwiftUI-observable state. One instance per
//  channel (see .codex / .claude). Intentionally has zero dependency on any
//  other boringNotch manager, and works whether or not the standalone
//  AgentLight menu-bar app is running.
//

import Darwin
import Foundation
import SwiftUI

enum AgentBreathingState: String {
    case idle
    case running
    case attention

    init(fileContents: String?) {
        let normalized = fileContents?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = AgentBreathingState(rawValue: normalized ?? "") ?? .idle
    }

    var color: Color {
        switch self {
        case .idle:
            return Color.white
        case .running:
            return Color(red: 1.00, green: 0.80, blue: 0.04)
        case .attention:
            return Color(red: 1.00, green: 0.04, blue: 0.02)
        }
    }

}

/// Watches a single state file with a DispatchSource (instant updates) plus a
/// slow polling backstop for the rare case a filesystem event is missed.
final class AgentBreathingMonitor: ObservableObject {
    static let codex = AgentBreathingMonitor(channel: "codex")
    static let claude = AgentBreathingMonitor(channel: "claude")

    /// Mirrors StateMonitor's staleRunningThreshold in the standalone
    /// AgentLight app: "running" with no file update for this long almost
    /// certainly means the agent's Stop hook never fired (crash, killed
    /// process, broken hook chain), so it's auto-cleared to idle rather than
    /// staying stuck yellow forever. This monitor does its own auto-reset so
    /// the dot stays correct even if AgentLight.app (which has the same
    /// safety net) isn't running.
    private static let staleRunningThreshold: TimeInterval = 360

    @Published private(set) var state: AgentBreathingState = .idle

    /// Foundation's homeDirectoryForCurrentUser (and NSHomeDirectory()) are
    /// virtualized under App Sandbox — they resolve to this app's own
    /// container (~/Library/Containers/<bundle-id>/Data), not the real
    /// user home, so a path built from them can never reach
    /// ~/.agentlight/<channel>/state regardless of file-access entitlements.
    /// getpwuid() reads the real passwd-database home, unaffected by that
    /// virtualization.
    private static var realHomeDirectory: URL {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir))
    }

    private let url: URL
    private let queue: DispatchQueue
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var lastSignature: String?

    private init(channel: String) {
        url = AgentBreathingMonitor.realHomeDirectory
            .appendingPathComponent(".agentlight")
            .appendingPathComponent(channel)
            .appendingPathComponent("state")
        queue = DispatchQueue(label: "boringNotch.AgentBreathingMonitor.\(channel)")
        start()
    }

    private func start() {
        readAndPublishIfChanged(force: true)
        startDirectoryMonitor()
        startFileMonitor()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.queue.async {
                self?.startFileMonitor()
                self?.readAndPublishIfChanged(force: false)
            }
        }
        pollTimer?.tolerance = 2.0
    }

    private func startDirectoryMonitor() {
        let path = url.deletingLastPathComponent().path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.startFileMonitor()
            self.readAndPublishIfChanged(force: false)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directorySource = source
        source.resume()
    }

    private func startFileMonitor() {
        fileSource?.cancel()
        fileSource = nil

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.readAndPublishIfChanged(force: false)
            if source.data.contains(.rename) || source.data.contains(.delete) {
                self.startFileMonitor()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        fileSource = source
        source.resume()
    }

    private func readAndPublishIfChanged(force: Bool) {
        let contents = try? String(contentsOf: url, encoding: .utf8)
        var state = AgentBreathingState(fileContents: contents)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        var modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var size = (attributes?[.size] as? NSNumber)?.intValue ?? -1

        if state == .running, modified > 0,
           Date().timeIntervalSince1970 - modified > Self.staleRunningThreshold {
            writeStaleFallback()
            state = .idle
            modified = Date().timeIntervalSince1970
            size = 5
        }

        let signature = "\(state.rawValue):\(modified):\(size)"
        guard force || signature != lastSignature else { return }
        lastSignature = signature

        DispatchQueue.main.async { [weak self] in
            self?.state = state
        }
    }

    /// Same atomic-replace approach as the standalone app's StateMonitor:
    /// write "idle" to a sibling temp file, then swap it in, so a reader
    /// never observes a half-written state file.
    private func writeStaleFallback() {
        let channelDirectory = url.deletingLastPathComponent()
        let tempURL = channelDirectory.appendingPathComponent("state.\(UUID().uuidString.prefix(6))")

        do {
            try "idle\n".write(to: tempURL, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}
