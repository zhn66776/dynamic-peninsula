//
//  DownloadProgressMonitor.swift
//  boringNotch
//
//  Watches ~/Downloads for an in-progress download (Safari's ".download"
//  and Chrome's ".crdownload" temp files) and publishes its growing size
//  for the closed-notch progress pill. Only tracks one download at a
//  time — the most recently started one — which is the simplest useful
//  version rather than a full download queue/manager.
//
//  Needs com.apple.security.temporary-exception.files.home-relative-path.read-only
//  for "/Downloads/" (see boringNotch.entitlements) since the app is
//  sandboxed and ~/Downloads isn't otherwise reachable without the user
//  picking it via an NSOpenPanel.
//

import Foundation

struct DownloadProgress: Equatable {
    let filename: String
    let bytesWritten: Int64
    let isComplete: Bool
}

final class DownloadProgressMonitor: ObservableObject {
    static let shared = DownloadProgressMonitor()

    @Published private(set) var activeDownload: DownloadProgress?

    private let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    private let queue = DispatchQueue(label: "boringNotch.DownloadProgressMonitor")
    private var directorySource: DispatchSourceFileSystemObject?
    private var trackTimer: Timer?
    private var trackedPath: String?
    private var lastSize: Int64 = -1
    private var completionDismissWorkItem: DispatchWorkItem?

    private init() {
        start()
    }

    private func start() {
        guard let downloadsURL else { return }
        let descriptor = open(downloadsURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scanForInProgressDownload()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directorySource = source
        source.resume()
        queue.async { [weak self] in self?.scanForInProgressDownload() }
    }

    private func scanForInProgressDownload() {
        guard let downloadsURL else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let inProgress = entries.filter { ["download", "crdownload"].contains($0.pathExtension) }
        let newest = inProgress.max { lhs, rhs in
            modificationDate(lhs) < modificationDate(rhs)
        }

        if let newest {
            beginTracking(url: newest)
        } else if trackedPath == nil {
            // Nothing in progress and nothing currently being tracked
            // through to completion — make sure no stale pill lingers.
            clearIfIdle()
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private func beginTracking(url: URL) {
        guard trackedPath != url.path else { return }
        completionDismissWorkItem?.cancel()
        trackedPath = url.path
        lastSize = -1
        trackTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.queue.async { self?.pollTrackedFile() }
        }
        trackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollTrackedFile() {
        guard let trackedPath else { return }
        let displayName = (trackedPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".crdownload", with: "")
            .replacingOccurrences(of: ".download", with: "")

        guard FileManager.default.fileExists(atPath: trackedPath) else {
            finishTracking(filename: displayName)
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: trackedPath)[.size] as? NSNumber)?.int64Value ?? lastSize
        lastSize = size
        DispatchQueue.main.async { [weak self] in
            self?.activeDownload = DownloadProgress(filename: displayName, bytesWritten: max(size, 0), isComplete: false)
        }
    }

    private func finishTracking(filename: String) {
        trackTimer?.invalidate()
        trackTimer = nil
        trackedPath = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeDownload = DownloadProgress(
                filename: filename,
                bytesWritten: max(self.lastSize, 0),
                isComplete: true
            )
            let workItem = DispatchWorkItem { [weak self] in
                self?.activeDownload = nil
            }
            self.completionDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
        }
    }

    private func clearIfIdle() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.trackedPath == nil else { return }
            self.activeDownload = nil
        }
    }
}
