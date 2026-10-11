//
//  ApprovalRequestCardView.swift
//  boringNotch
//
//  Read-only FYI for AgentApprovalMonitor's most recent Codex
//  PermissionRequest: tool name, command, cwd. Sized and padded to match
//  the other modules in this same slot (NotchHomeView, SystemMonitorView)
//  — no own background/corner radius, since that's what the shared notch
//  shape in ContentView already provides.
//
//  There are intentionally no Deny/Allow buttons here. Codex fires
//  PermissionRequest for every approval-eligible action whether a human
//  or its own `auto_review` reviewer agent is the one actually deciding,
//  and there's no supported way for this app to tell which is which -
//  see AgentApprovalMonitor's header for why. Showing actionable buttons
//  here would mean guessing at "needs you" for requests auto_review was
//  already about to resolve on its own, and there's no channel left to
//  send a decision back to Codex through even if the user tapped one.
//  So this card just says what happened and points at the real app; it
//  clears itself automatically after AgentApprovalMonitor's TTL.
//

import SwiftUI

struct ApprovalRequestCardView: View {
    let request: AgentApprovalNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.yellow)
                Text("Codex asked to run \(request.toolName)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !request.cwd.isEmpty {
                    Text((request.cwd as NSString).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            if !request.command.isEmpty {
                Text(request.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                Text("Check the Codex app if it's waiting on you")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: 123)
    }
}
