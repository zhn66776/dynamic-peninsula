//
//  DownloadProgressDropdown.swift
//  boringNotch
//
//  Dynamic-Island-style pill that hangs below the closed notch/camera
//  while a Downloads-folder download is in progress (see
//  DownloadProgressMonitor), matching SystemMonitorAlertDropdown's visual
//  language. Unlike that alert dropdown, this one has no close button and
//  auto-dismisses itself shortly after the download completes —
//  DownloadProgressMonitor clears `activeDownload` on its own timer.
//

import SwiftUI

struct DownloadProgressDropdown: View {
    let download: DownloadProgress

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: download.isComplete ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(download.isComplete ? .green : .white)
                .symbolEffect(.pulse, isActive: !download.isComplete)
            VStack(alignment: .leading, spacing: 1) {
                Text(download.filename)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(download.isComplete
                     ? String(localized: "Download complete")
                     : ByteCountFormatter.string(fromByteCount: download.bytesWritten, countStyle: .binary))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        .frame(maxWidth: 260)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
