//
//  QuotaDropPresenter.swift
//  boringNotch
//
//  One queue for the ~6s full-pill "weekly quota dropped" takeover
//  (ContentView.quotaDropRevealPill), shared by CodexQuotaMonitor and
//  ClaudeQuotaMonitor so the two can never fight over the pill:
//
//  - Only one reveal is on screen at a time; a drop from the other agent
//    waits its turn and plays right after.
//  - A second drop from the *same* agent while its reveal is up (or
//    queued) is merged into it — from the original value to the newest
//    one — rather than playing twice.
//  - Nothing plays while a Codex approval notice is showing: the takeover
//    hides the whole notch, approval card included, so queued reveals
//    wait until the notice clears.
//

import Combine
import Foundation

enum QuotaProvider: Hashable {
    case codex
    case claude
}

@MainActor
final class QuotaDropPresenter: ObservableObject {
    static let shared = QuotaDropPresenter()

    /// A confirmed drop between two consecutive readings — never a rise
    /// (e.g. the weekly reset jumping back up).
    struct Drop: Hashable, Identifiable {
        let id = UUID()
        let provider: QuotaProvider
        let from: Int
        let to: Int
    }

    @Published private(set) var current: Drop?

    private static let revealDuration: Duration = .seconds(6)

    private var queue: [Drop] = []
    private var clearTask: Task<Void, Never>?
    private var approvalSubscription: AnyCancellable?

    private init() {
        // receive(on:) delivers after pendingRequest has actually been
        // assigned, so presentNextIfIdle sees the new (nil) value.
        approvalSubscription = AgentApprovalMonitor.shared.$pendingRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                if request == nil { self?.presentNextIfIdle() }
            }
    }

    func enqueue(provider: QuotaProvider, from: Int, to: Int) {
        if let current, current.provider == provider {
            show(Drop(provider: provider, from: current.from, to: to))
        } else if let index = queue.firstIndex(where: { $0.provider == provider }) {
            queue[index] = Drop(provider: provider, from: queue[index].from, to: to)
        } else {
            queue.append(Drop(provider: provider, from: from, to: to))
            presentNextIfIdle()
        }
    }

    private func presentNextIfIdle() {
        guard current == nil,
              AgentApprovalMonitor.shared.pendingRequest == nil,
              !queue.isEmpty
        else { return }
        show(queue.removeFirst())
    }

    private func show(_ drop: Drop) {
        current = drop
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.revealDuration)
            guard !Task.isCancelled, let self else { return }
            self.current = nil
            self.presentNextIfIdle()
        }
    }
}
