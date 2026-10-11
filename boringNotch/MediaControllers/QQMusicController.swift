//
//  QQMusicController.swift
//  boringNotch
//
//  QQ Music does not expose an AppleScript dictionary. Its compact playback
//  bar exposes stable Accessibility labels for controls, while its loopback
//  companion service provides the exact playback timeline used by the slider.
//

import AppKit
import Combine
import Foundation

final class QQMusicController: ObservableObject, MediaControllerProtocol, @unchecked Sendable {
    private static let bundleIdentifier = "com.tencent.QQMusicMac"

    @Published private var playbackState = PlaybackState(
        bundleIdentifier: QQMusicController.bundleIdentifier,
        isPlaying: false,
        title: "QQ Music",
        artist: "Connecting…",
        album: "QQ Music",
        playbackRate: 0,
        lastUpdated: Date()
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    // QQ Music's mini playback bar exposes no volume slider to Accessibility
    // (only transport buttons — see QQMusicAccessibilityBridge), so there is
    // no reliable per-app volume to read or set. Falling back to the system
    // output volume (same CoreAudio path the app's own volume HUD uses)
    // still gives a working, always-available slider instead of a disabled
    // one.
    var supportsVolumeControl: Bool { true }
    var supportsFavorite: Bool { true }

    private var pollingTask: Task<Void, Never>?
    private var lastLoggedSnapshot: QQMusicPlaybackSnapshot?
    private var didLogMissingAccessibility = false
    private let localPlayerClient = QQMusicLocalPlayerClient()
    private var cachedAccessibilitySnapshot: QQMusicPlaybackSnapshot?
    private var lastAccessibilityRefresh = Date.distantPast
    private var lastTimelineTrackKey: String?
    private var lastArtworkURL: String?
    private var artworkFetchTask: Task<Void, Never>?
    private let accessibilityRefreshInterval: TimeInterval = 5

    init() {
        pollingTask = Task { [weak self] in
            var accessibilityAuthorized = await XPCHelperClient.shared
                .ensureAccessibilityAuthorization(promptIfNeeded: true)
            var lastAuthorizationCheck = Date()
            var needsInitialAccessibilityRefresh = accessibilityAuthorized

            while !Task.isCancelled {
                if !accessibilityAuthorized,
                   Date().timeIntervalSince(lastAuthorizationCheck) >= 5
                {
                    accessibilityAuthorized = await XPCHelperClient.shared
                        .ensureAccessibilityAuthorization(promptIfNeeded: false)
                    lastAuthorizationCheck = Date()
                    needsInitialAccessibilityRefresh = accessibilityAuthorized
                }

                if accessibilityAuthorized {
                    self?.didLogMissingAccessibility = false
                    await self?.refreshPlaybackInfo(
                        forceAccessibilityRefresh: needsInitialAccessibilityRefresh
                    )
                    needsInitialAccessibilityRefresh = false
                } else {
                    if self?.didLogMissingAccessibility == false {
                        NSLog("QQ Music: waiting for Accessibility authorization")
                        self?.didLogMissingAccessibility = true
                    }
                    await self?.publishStatus(
                        title: "QQ Music",
                        artist: "Enable Accessibility access"
                    )
                }

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
        }
    }

    deinit {
        pollingTask?.cancel()
        artworkFetchTask?.cancel()
        localPlayerClient.stop()
    }

    func play() async {
        await performLocalControl(named: "play") {
            await localPlayerClient.play()
        }
    }

    func pause() async {
        await performLocalControl(named: "pause") {
            await localPlayerClient.pause()
        }
    }

    func togglePlay() async {
        await performLocalControl(named: "playPause") {
            await localPlayerClient.togglePlayback()
        }
    }

    func nextTrack() async {
        await performLocalControl(named: "next") {
            await localPlayerClient.nextTrack()
        }
    }

    func previousTrack() async {
        await performLocalControl(named: "previous") {
            await localPlayerClient.previousTrack()
        }
    }

    func seek(to time: Double) async {
        guard time.isFinite else { return }

        let duration = await MainActor.run { playbackState.duration }
        let target = min(max(0, time), max(0, duration - 0.05))
        guard duration > 0, await localPlayerClient.seek(to: target) else { return }

        await MainActor.run {
            var state = playbackState
            state.currentTime = target
            state.lastUpdated = Date()
            playbackState = state
        }

        try? await Task.sleep(for: .milliseconds(120))
        await refreshPlaybackInfo(forceAccessibilityRefresh: false)
    }

    func toggleShuffle() async {
        await performAccessibilityAction(.cyclePlayMode)
    }

    func toggleRepeat() async {
        await performAccessibilityAction(.cyclePlayMode)
    }

    func setVolume(_ level: Double) async {
        await MainActor.run {
            VolumeManager.shared.setAbsolute(Float32(level))
        }
        await MainActor.run {
            var state = playbackState
            state.volume = level
            playbackState = state
        }
    }

    func setFavorite(_ favorite: Bool) async {
        let currentValue = await MainActor.run { playbackState.isFavorite }
        guard currentValue != favorite else { return }
        await performAccessibilityAction(.toggleFavorite)
    }

    func isActive() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).isEmpty
    }

    func updatePlaybackInfo() async {
        await refreshPlaybackInfo(forceAccessibilityRefresh: true)
    }

    private func refreshPlaybackInfo(forceAccessibilityRefresh: Bool) async {
        guard isActive() else {
            await publishStatus(title: "QQ Music", artist: "Open QQ Music to connect")
            return
        }

        let timeline = await localPlayerClient.latestSnapshot()
        let timelineTrackKey = timeline.map {
            "\($0.title ?? "")\u{1F}\($0.artist ?? "")"
        }
        let timelineTrackChanged = timelineTrackKey != nil
            && timelineTrackKey != lastTimelineTrackKey
        let accessibilityRefreshDue = Date().timeIntervalSince(lastAccessibilityRefresh)
            >= accessibilityRefreshInterval

        if forceAccessibilityRefresh
            || timelineTrackChanged
            || accessibilityRefreshDue
        {
            lastAccessibilityRefresh = Date()
            if let snapshot = await XPCHelperClient.shared.qqMusicPlaybackSnapshot() {
                cachedAccessibilitySnapshot = snapshot
            }
        }

        if let timelineTrackKey {
            lastTimelineTrackKey = timelineTrackKey
        }

        let snapshot = cachedAccessibilitySnapshot
        guard timeline != nil || snapshot != nil else { return }

        if let snapshot, snapshot != lastLoggedSnapshot {
            NSLog(
                "QQ Music connected: %@ — %@ (playing: %@)",
                snapshot.title,
                snapshot.artist,
                snapshot.isPlaying ? "yes" : "no"
            )
            lastLoggedSnapshot = snapshot
        }

        let title = timeline?.title ?? snapshot?.title ?? "QQ Music"
        let artist = timeline?.artist ?? snapshot?.artist ?? "Unknown Artist"
        let album = timeline?.album ?? "QQ Music"
        let duration = max(0, timeline?.duration ?? 0)
        let currentTime = min(max(0, timeline?.currentTime ?? 0), duration)
        let isPlaying = timeline?.isPlaying ?? snapshot?.isPlaying ?? false
        let progressUpdatedAt = timeline?.progressUpdatedAt ?? Date()

        let artworkURL = timeline?.artworkURLString
        let state = await MainActor.run {
            let existingArtwork = artworkURL == lastArtworkURL ? playbackState.artwork : nil
            playbackState = PlaybackState(
                bundleIdentifier: Self.bundleIdentifier,
                isPlaying: isPlaying,
                title: title,
                artist: artist,
                album: album,
                currentTime: currentTime,
                duration: duration,
                playbackRate: isPlaying ? 1 : 0,
                isShuffled: snapshot?.isShuffled ?? playbackState.isShuffled,
                repeatMode: snapshot.flatMap { RepeatMode(rawValue: $0.repeatMode) }
                    ?? playbackState.repeatMode,
                lastUpdated: progressUpdatedAt,
                artwork: existingArtwork,
                volume: Double(VolumeManager.shared.rawVolume),
                isFavorite: snapshot?.isFavorite ?? playbackState.isFavorite
            )
            return playbackState
        }
        fetchArtworkIfNeeded(from: artworkURL, for: state)
    }

    private func performLocalControl(
        named command: String,
        operation: () async -> Bool
    ) async {
        guard await operation() else {
            NSLog("QQ Music local control failed: %@", command)
            return
        }

        try? await Task.sleep(for: .milliseconds(180))
        await refreshPlaybackInfo(forceAccessibilityRefresh: false)
    }

    private func fetchArtworkIfNeeded(from urlString: String?, for state: PlaybackState) {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else {
            artworkFetchTask?.cancel()
            artworkFetchTask = nil
            lastArtworkURL = nil
            return
        }
        guard urlString != lastArtworkURL || state.artwork == nil else { return }

        artworkFetchTask?.cancel()
        artworkFetchTask = Task { [weak self] in
            do {
                let data = try await ImageService.shared.fetchImageData(from: url)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.playbackState.title == state.title,
                          self.playbackState.artist == state.artist else { return }
                    var updated = self.playbackState
                    updated.artwork = data
                    self.playbackState = updated
                    self.lastArtworkURL = urlString
                    self.artworkFetchTask = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.artworkFetchTask = nil
                }
            }
        }
    }

    private func performAccessibilityAction(_ action: QQMusicControlAction) async {
        guard await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: false)
        else { return }

        guard await XPCHelperClient.shared.performQQMusicAction(action) else { return }
        try? await Task.sleep(for: .milliseconds(180))
        await refreshPlaybackInfo(forceAccessibilityRefresh: true)
    }

    private func publishStatus(title: String, artist: String) async {
        await MainActor.run {
            var state = playbackState
            state.isPlaying = false
            state.title = title
            state.artist = artist
            state.album = "QQ Music"
            state.currentTime = 0
            state.duration = 0
            state.playbackRate = 0
            state.lastUpdated = Date()
            playbackState = state
        }
    }
}
