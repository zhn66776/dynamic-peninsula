//
//  NetworkConnectivityMonitor.swift
//  boringNotch
//
//  Standalone module ported from the sibling Connectivity-monitor project's
//  detection idea, trimmed down to just the part this app wants: knowing
//  whether the internet is reachable at all. None of that project's HPC
//  ping/latency/history tracking is needed here — just a persistent "no
//  internet" alert that stays up until the user dismisses it or the
//  connection comes back.
//
//  Two signals feed `isOffline`: NWPathMonitor (fast, but a Wi-Fi link can
//  be "satisfied" while sitting behind a captive portal or a router with no
//  upstream) and a periodic real HTTP probe (slower, but actually proves an
//  internet host is reachable).
//
//  The HTTP probe is the only thing allowed to flip `isOffline` in either
//  direction. NWPathMonitor is treated purely as a *hint* that something
//  changed and we should re-probe right now: VPN/tunnel daemons (Tailscale
//  on utunN, etc.), Wi-Fi roaming and sleep/wake all make the path flicker
//  through `.unsatisfied` for a moment while the internet is perfectly fine,
//  so acting on that status directly produced spurious "Internet connection
//  lost" alerts. Going offline requires two consecutive failed probes (the
//  second one retried quickly, not a full interval later); coming back
//  online is immediate on the first success, and a path change or wake from
//  sleep triggers a probe straight away so recovery doesn't wait for the
//  next scheduled tick.
//

import AppKit
import Foundation
import Network
import os

private let networkLog = Logger(subsystem: "com.dynamicpeninsula.networkConnectivity", category: "monitor")

struct NetworkOutageAlert: Identifiable, Equatable {
    let id: UUID
    let since: Date
}

@MainActor
final class NetworkConnectivityMonitor: ObservableObject {
    static let shared = NetworkConnectivityMonitor()

    @Published private(set) var isOffline = false
    /// The currently displayed alert, if any. Distinct from `isOffline`:
    /// dismissing sets this to nil without clearing `isOffline`, so the
    /// same outage doesn't immediately re-show the card the user just
    /// closed — it only comes back if the connection drops again after
    /// having recovered.
    @Published private(set) var activeAlert: NetworkOutageAlert?

    private static let probeURL = URL(string: "https://www.apple.com/library/test/success.html")!
    private static let fallbackProbeURL = URL(string: "https://1.1.1.1/cdn-cgi/trace")!
    /// Steady-state gap between probes while nothing looks wrong.
    private let probeInterval: TimeInterval = 10
    /// Gap before the confirming re-probe after a single failure.
    private let retryInterval: TimeInterval = 3
    /// How long to let the network settle after a path change or wake
    /// before probing — routes/DNS are usually still being reconfigured
    /// during the first second or so.
    private let settleDelay: TimeInterval = 1.5
    private let failuresBeforeOffline = 2

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "boringNotch.NetworkConnectivityMonitor.path")
    private var pathSatisfied = true
    private var consecutiveProbeFailures = 0
    private var probeTask: Task<Void, Never>?
    private var probeInFlight = false
    private var pendingNudge: String?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.pathSatisfied != satisfied
                self.pathSatisfied = satisfied
                networkLog.info("path \(String(describing: path.status), privacy: .public) ifs=[\(interfaces, privacy: .public)]")
                // Any path change — in either direction — is a reason to
                // find out the truth now rather than at the next tick. Not
                // a reason to declare anything on its own.
                if changed || !satisfied {
                    self.scheduleProbe(after: self.settleDelay, reason: "path change")
                }
            }
        }
        pathMonitor.start(queue: pathQueue)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A probe that fired mid-sleep (or right as the lid opened)
                // shouldn't count against us.
                self.consecutiveProbeFailures = 0
                self.scheduleProbe(after: self.settleDelay, reason: "wake")
            }
        }

        scheduleProbe(after: 0, reason: "startup")
    }

    deinit {
        pathMonitor.cancel()
        probeTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func dismissAlert() {
        activeAlert = nil
    }

    /// Replaces whatever probe is currently scheduled with one `delay`
    /// seconds from now. The probe loop is a single self-rescheduling task
    /// so there's never more than one timer pending, and a path-change or
    /// wake nudge simply preempts the regular interval. If a probe is
    /// already awaiting the network, the nudge is parked instead — that
    /// probe schedules the follow-up when it finishes — so an in-flight
    /// request is never cancelled out from under the loop.
    private func scheduleProbe(after delay: TimeInterval, reason: String) {
        if probeInFlight {
            pendingNudge = reason
            return
        }
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.runProbe(reason: reason)
        }
    }

    private func runProbe(reason: String) async {
        probeInFlight = true
        let result = await Self.probeInternet()
        probeInFlight = false

        let nextDelay: TimeInterval
        switch result {
        case .reachable(let url, let ms):
            networkLog.info("probe ok (\(reason, privacy: .public)) via \(url.host ?? "?", privacy: .public) \(ms)ms")
            consecutiveProbeFailures = 0
            markOnline()
            nextDelay = probeInterval
        case .unreachable(let detail):
            consecutiveProbeFailures += 1
            networkLog.warning("probe FAILED #\(self.consecutiveProbeFailures) (\(reason, privacy: .public)) pathSatisfied=\(self.pathSatisfied) \(detail, privacy: .public)")
            if consecutiveProbeFailures >= failuresBeforeOffline {
                markOffline()
                nextDelay = probeInterval
            } else {
                nextDelay = retryInterval
            }
        }

        if let nudge = pendingNudge {
            pendingNudge = nil
            scheduleProbe(after: min(settleDelay, nextDelay), reason: nudge)
        } else {
            scheduleProbe(after: nextDelay, reason: consecutiveProbeFailures == 0 ? "interval" : "retry")
        }
    }

    private func markOffline() {
        guard !isOffline else { return }
        networkLog.error("marking OFFLINE")
        isOffline = true
        activeAlert = NetworkOutageAlert(id: UUID(), since: Date())
    }

    private func markOnline() {
        guard isOffline else { return }
        networkLog.info("marking ONLINE")
        isOffline = false
        activeAlert = nil
    }

    private enum ProbeResult {
        case reachable(URL, Int)
        case unreachable(String)
    }

    private static func probeInternet() async -> ProbeResult {
        var failures: [String] = []
        for url in [probeURL, fallbackProbeURL] {
            let started = Date()
            switch await probeHTTP(url) {
            case .success:
                return .reachable(url, Int(Date().timeIntervalSince(started) * 1000))
            case .failure(let error):
                failures.append("\(url.host ?? "?"): \(error.localizedDescription)")
            }
        }
        return .unreachable(failures.joined(separator: " | "))
    }

    private enum ProbeError: LocalizedError {
        case notHTTP
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notHTTP: return "non-HTTP response"
            case .badStatus(let code): return "HTTP \(code)"
            }
        }
    }

    private static func probeHTTP(_ url: URL) async -> Result<Void, Error> {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 6
        )
        request.httpMethod = "GET"
        request.setValue("boringNotch/NetworkConnectivityMonitor", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(ProbeError.notHTTP)
            }
            guard (200..<500).contains(httpResponse.statusCode) else {
                return .failure(ProbeError.badStatus(httpResponse.statusCode))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
