//
//  QQMusicLocalPlayerClient.swift
//  boringNotch
//
//  QQ Music exposes a loopback-only transport service for companion controls.
//  It publishes newline-delimited JSON snapshots and accepts seek positions in
//  milliseconds. Keeping one connection open gives the notch an exact timeline
//  without screen scraping or per-track web searches.
//

import Foundation
import Network

struct QQMusicTimelineSnapshot: Equatable, Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let artworkURLString: String?
    let currentTime: TimeInterval
    let duration: TimeInterval
    let status: Int?
    let isPlaying: Bool?
    let progressUpdatedAt: Date
}

final class QQMusicLocalPlayerClient: @unchecked Sendable {
    private struct MutableSnapshot {
        var title: String?
        var artist: String?
        var album: String?
        var artworkURLString: String?
        var currentTime: TimeInterval = 0
        var duration: TimeInterval = 0
        var status: Int?
        var isPlaying: Bool?
        var progressUpdatedAt = Date()

        var immutable: QQMusicTimelineSnapshot {
            QQMusicTimelineSnapshot(
                title: title,
                artist: artist,
                album: album,
                artworkURLString: artworkURLString,
                currentTime: currentTime,
                duration: duration,
                status: status,
                isPlaying: isPlaying,
                progressUpdatedAt: progressUpdatedAt
            )
        }
    }

    private struct PendingWrite {
        let data: Data
        let completion: @Sendable (Bool) -> Void
    }

    private struct PendingSeek {
        let target: TimeInterval
        let expiresAt: Date
    }

    private static let port = NWEndpoint.Port(rawValue: 19_443)!
    private static let maximumBufferedBytes = 1_048_576

    private let queue = DispatchQueue(label: "theboringteam.boringnotch.qqmusic.timeline")
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var snapshot = MutableSnapshot()
    private var pendingWrites: [PendingWrite] = []
    private var pendingSeek: PendingSeek?
    private var reconnectWorkItem: DispatchWorkItem?
    private var isReady = false
    private var stopped = false
    private var didLogConnection = false

    init() {
        queue.async { [weak self] in
            self?.connectIfNeeded()
        }
    }

    deinit {
        reconnectWorkItem?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    func latestSnapshot() async -> QQMusicTimelineSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                self.connectIfNeeded()
                guard self.snapshot.duration > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.snapshot.immutable)
            }
        }
    }

    func play() async -> Bool {
        await performControl(command: "playorpause", desiredPlayingState: true)
    }

    func pause() async -> Bool {
        await performControl(command: "playorpause", desiredPlayingState: false)
    }

    func togglePlayback() async -> Bool {
        await performControl(command: "playorpause", togglesPlayingState: true)
    }

    func nextTrack() async -> Bool {
        await performControl(command: "next")
    }

    func previousTrack() async -> Bool {
        await performControl(command: "prev")
    }

    func seek(to requestedTime: TimeInterval) async -> Bool {
        guard requestedTime.isFinite else { return false }

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                let upperBound = max(0, self.snapshot.duration - 0.05)
                guard upperBound > 0 else {
                    continuation.resume(returning: false)
                    return
                }

                let target = min(max(0, requestedTime), upperBound)
                let milliseconds = Int64((target * 1_000).rounded())
                guard milliseconds >= 0, milliseconds <= UInt32.max else {
                    continuation.resume(returning: false)
                    return
                }

                self.pendingSeek = PendingSeek(
                    target: target,
                    expiresAt: Date().addingTimeInterval(2)
                )
                self.snapshot.currentTime = target
                self.snapshot.progressUpdatedAt = Date()

                guard let command = Self.commandData(
                    command: "seek",
                    parameters: ["value": milliseconds]
                ) else {
                    self.pendingSeek = nil
                    continuation.resume(returning: false)
                    return
                }

                self.enqueue(command) { success in
                    continuation.resume(returning: success)
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.failPendingWrites()
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
            self.isReady = false
            self.receiveBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func connectIfNeeded() {
        guard !stopped, connection == nil else { return }

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: Self.port,
            using: .tcp
        )
        self.connection = connection
        isReady = false

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            self.handleConnectionState(state, connection: connection)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            isReady = true
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil

            if !didLogConnection {
                NSLog("QQ Music timeline connected on localhost")
                didLogConnection = true
            }

            receiveNextMessage(on: connection)
            sendLogin(on: connection)
            flushPendingWrites(on: connection)

        case .waiting, .failed:
            finishConnection(connection, shouldReconnect: true)

        case .cancelled:
            finishConnection(connection, shouldReconnect: !stopped)

        case .setup, .preparing:
            break

        @unknown default:
            finishConnection(connection, shouldReconnect: true)
        }
    }

    private func sendLogin(on connection: NWConnection) {
        guard let data = Self.commandData(
            command: "login",
            parameters: [
                "appName": "Dynamic Peninsula",
                "appKey": "dynamic-peninsula",
            ]
        ) else { return }

        send(data, on: connection) { _ in }
    }

    private func enqueue(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
        if isReady, let connection {
            send(data, on: connection, completion: completion)
            return
        }

        pendingWrites.append(PendingWrite(data: data, completion: completion))
        connectIfNeeded()
    }

    private func flushPendingWrites(on connection: NWConnection) {
        let writes = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        for write in writes {
            send(write.data, on: connection, completion: write.completion)
        }
    }

    private func send(
        _ data: Data,
        on connection: NWConnection,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error == nil)
        })
    }

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 262_144
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processCompleteLines()
            }

            if error != nil || isComplete {
                self.finishConnection(connection, shouldReconnect: true)
            } else {
                self.receiveNextMessage(on: connection)
            }
        }
    }

    private func processCompleteLines() {
        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            var line = Data(receiveBuffer[..<newlineIndex])
            receiveBuffer.removeSubrange(...newlineIndex)
            if line.last == 0x0D {
                line.removeLast()
            }
            process(line: line)
        }

        if receiveBuffer.count > Self.maximumBufferedBytes {
            receiveBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func process(line: Data) {
        guard !line.isEmpty,
              let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let notification = message["notify"] as? String,
              let data = message["data"] as? [String: Any]
        else { return }

        switch notification {
        case "song":
            let newTitle = Self.nonEmptyString(data["title"])
            let newArtist = Self.nonEmptyString(data["singer"])
            let trackChanged = newTitle != snapshot.title || newArtist != snapshot.artist

            snapshot.title = newTitle
            snapshot.artist = newArtist
            snapshot.album = Self.nonEmptyString(data["album"])
            snapshot.artworkURLString = Self.nonEmptyString(data["picurl"])

            if trackChanged {
                snapshot.currentTime = 0
                snapshot.duration = 0
                snapshot.progressUpdatedAt = Date()
                pendingSeek = nil
            }

        case "status":
            let status = Self.number(data["value"])?.intValue
            snapshot.status = status
            if status == 3 {
                snapshot.isPlaying = true
            } else if status == 4 {
                snapshot.isPlaying = false
            }

        case "progress":
            guard let durationMilliseconds = Self.number(data["duration"])?.doubleValue,
                  let playbackMilliseconds = Self.number(data["playtime"])?.doubleValue
            else { return }

            let now = Date()
            let duration = max(0, durationMilliseconds / 1_000)
            let currentTime = min(max(0, playbackMilliseconds / 1_000), duration)
            snapshot.duration = duration

            if let pendingSeek,
               now < pendingSeek.expiresAt,
               abs(currentTime - pendingSeek.target) > 1.5
            {
                return
            }

            pendingSeek = nil
            snapshot.currentTime = currentTime
            snapshot.progressUpdatedAt = now

        default:
            break
        }
    }

    private func finishConnection(_ connection: NWConnection, shouldReconnect: Bool) {
        guard self.connection === connection else { return }

        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        isReady = false
        receiveBuffer.removeAll(keepingCapacity: false)
        failPendingWrites()

        if shouldReconnect {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard !stopped, reconnectWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.connectIfNeeded()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func failPendingWrites() {
        let writes = pendingWrites
        pendingWrites.removeAll(keepingCapacity: false)
        for write in writes {
            write.completion(false)
        }
    }

    private func performControl(
        command: String,
        desiredPlayingState: Bool? = nil,
        togglesPlayingState: Bool = false
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                self.connectIfNeeded()

                if let desiredPlayingState {
                    if self.snapshot.isPlaying == desiredPlayingState {
                        continuation.resume(returning: true)
                        return
                    }

                    // QQ Music exposes only a toggle command. Refuse to guess if
                    // the current state has not arrived yet.
                    guard self.snapshot.isPlaying != nil else {
                        continuation.resume(returning: false)
                        return
                    }
                }

                guard let data = Self.commandData(command: command, parameters: [:]) else {
                    continuation.resume(returning: false)
                    return
                }

                if let desiredPlayingState {
                    self.snapshot.isPlaying = desiredPlayingState
                    self.snapshot.status = desiredPlayingState ? 3 : 4
                } else if togglesPlayingState, let isPlaying = self.snapshot.isPlaying {
                    self.snapshot.isPlaying = !isPlaying
                    self.snapshot.status = isPlaying ? 4 : 3
                }
                self.snapshot.progressUpdatedAt = Date()

                self.enqueue(data) { success in
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private static func commandData(
        command: String,
        parameters: [String: Any]
    ) -> Data? {
        guard JSONSerialization.isValidJSONObject([
            "cmd": command,
            "params": parameters,
        ]),
        var data = try? JSONSerialization.data(withJSONObject: [
            "cmd": command,
            "params": parameters,
        ])
        else { return nil }

        data.append(0x0A)
        return data
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }
}
