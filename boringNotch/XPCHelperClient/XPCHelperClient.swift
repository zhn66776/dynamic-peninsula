import Foundation
import Cocoa
import AsyncXPCConnection

struct QQMusicPlaybackSnapshot: Codable, Equatable, Sendable {
    let title: String
    let artist: String
    let isPlaying: Bool
    let isFavorite: Bool
    let isShuffled: Bool
    let repeatMode: Int
}

enum QQMusicControlAction: String, Sendable {
    case playPause
    case play
    case pause
    case next
    case previous
    case toggleFavorite
    case cyclePlayMode
}

final class XPCHelperClient: NSObject {
    nonisolated static let shared = XPCHelperClient()
    
    private let serviceName = "\(Bundle.main.bundleIdentifier!).BoringNotchXPCHelper"
    
    private var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
    private var connection: NSXPCConnection?
    private var lastKnownAuthorization: Bool?
    private var monitoringTask: Task<Void, Never>?
    private let systemMonitorRequestGate = SystemMonitorXPCRequestGate()
    
    deinit {
        connection?.invalidate()
        stopMonitoringAccessibilityAuthorization()
    }
    
    // MARK: - Connection Management (Main Actor Isolated)
    
    @MainActor
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol> {
        if let existing = remoteService {
            return existing
        }
        
        let conn = NSXPCConnection(serviceName: serviceName)
        
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.resume()
        
        let service = RemoteXPCService<BoringNotchXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchXPCHelperProtocol.self
        )
        
        connection = conn
        remoteService = service
        return service
    }
    
    @MainActor
    private func getRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol>? {
        remoteService
    }
    
    @MainActor
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring
    nonisolated func startMonitoringAccessibilityAuthorization(every interval: TimeInterval = 3.0) {
        // Ensure only one monitor exists
        stopMonitoringAccessibilityAuthorization()
        monitoringTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                // Call the helper method periodically which will notify on change
                _ = await self.isAccessibilityAuthorized()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
            }
        }
    }

    nonisolated func stopMonitoringAccessibilityAuthorization() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // Expose whether the client is actively monitoring (useful for tests/debug)
    var isMonitoring: Bool {
        return monitoringTask != nil
    }
    
    // MARK: - Accessibility
    
    nonisolated func requestAccessibilityAuthorization() {
        Task {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            try? await service.withService { service in
                service.requestAccessibilityAuthorization()
            }
        }
    }
    
    nonisolated func isAccessibilityAuthorized() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.isAccessibilityAuthorized { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    nonisolated func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.ensureAccessibilityAuthorization(promptIfNeeded) { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }

    // MARK: - QQ Music

    nonisolated func qqMusicPlaybackSnapshot() async -> QQMusicPlaybackSnapshot? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let payload: NSData? = try await service.withContinuation { service, continuation in
                service.qqMusicPlaybackSnapshot { data in
                    continuation.resume(returning: data)
                }
            }
            guard let payload else { return nil }
            return try JSONDecoder().decode(
                QQMusicPlaybackSnapshot.self,
                from: payload as Data
            )
        } catch {
            return nil
        }
    }

    nonisolated func performQQMusicAction(_ action: QQMusicControlAction) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.performQQMusicAction(action.rawValue) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    // MARK: - System Monitor

    nonisolated func systemMonitorSnapshot(
        request: SystemMonitorXPCRequest
    ) async throws -> SystemMonitorXPCSnapshot {
        let requestData: Data
        do {
            requestData = try request.encoded()
        } catch {
            throw SystemMonitorXPCError.requestEncodingFailed
        }

        guard await systemMonitorRequestGate.begin() else {
            throw SystemMonitorXPCError.requestAlreadyInFlight
        }
        let service = await MainActor.run { ensureRemoteService() }

        return try await withCheckedThrowingContinuation { continuation in
            let state = SystemMonitorXPCReplyState(continuation: continuation)

            Task { [systemMonitorRequestGate] in
                do {
                    let response: (NSData?, NSString?) = try await service.withContinuation {
                        service, continuation in
                        service.systemMonitorSnapshot(requestData as NSData) { data, error in
                            continuation.resume(returning: (data, error))
                        }
                    }
                    await systemMonitorRequestGate.end()
                    state.resolve(Self.decodeSystemMonitorResponse(response))
                } catch {
                    await systemMonitorRequestGate.end()
                    state.resolve(.failure(.transportInterrupted))
                }
            }
            state.startTimeout(after: .milliseconds(800))
        }
    }

    nonisolated private static func decodeSystemMonitorResponse(
        _ response: (NSData?, NSString?)
    ) -> Result<SystemMonitorXPCSnapshot, SystemMonitorXPCError> {
        if let error = response.1 {
            return .failure(.helperRejected(error as String))
        }
        guard let data = response.0 else {
            return .failure(.invalidResponse)
        }
        do {
            return .success(try SystemMonitorXPCSnapshot.decode(from: data as Data))
        } catch let error as SystemMetricsProviderError {
            if case let .schemaMismatch(expected, actual) = error {
                return .failure(.schemaMismatch(expected: expected, actual: actual))
            }
            return .failure(.responseDecodingFailed)
        } catch {
            return .failure(.responseDecodingFailed)
        }
    }
    
    // MARK: - Keyboard Brightness
    
    nonisolated func isKeyboardBrightnessAvailable() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isKeyboardBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func currentKeyboardBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentKeyboardBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setKeyboardBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setKeyboardBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
    
    // MARK: - Screen Brightness
    
    nonisolated func isScreenBrightnessAvailable() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isScreenBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func currentScreenBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentScreenBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setScreenBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
}

actor SystemMonitorXPCRequestGate {
    private var requestIsInFlight = false

    func begin() -> Bool {
        guard !requestIsInFlight else { return false }
        requestIsInFlight = true
        return true
    }

    func end() {
        requestIsInFlight = false
    }
}

final class SystemMonitorXPCReplyState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SystemMonitorXPCSnapshot, Error>?

    init(continuation: CheckedContinuation<SystemMonitorXPCSnapshot, Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<SystemMonitorXPCSnapshot, SystemMonitorXPCError>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result.mapError { $0 as Error })
    }

    func startTimeout(after duration: Duration) {
        Task { [self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            resolve(.failure(.timedOut))
        }
    }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}
