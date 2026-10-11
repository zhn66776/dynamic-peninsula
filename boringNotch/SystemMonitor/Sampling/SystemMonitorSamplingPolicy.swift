import Foundation

enum SamplingContext: Equatable, Sendable {
    case disabled
    case suspended
    case background
    case foreground
}

enum SamplingDomain: CaseIterable, Hashable, Sendable {
    case cpu
    case gpu
    case memory
    case diskIO
    case temperature
    case fans
    case capacity
    case optional
    case network
}

struct SystemMonitorSamplingPolicy: Equatable, Sendable {
    let context: SamplingContext
    let isLowPowerMode: Bool
    let backoffLevel: Int

    init(context: SamplingContext, isLowPowerMode: Bool, backoffLevel: Int) {
        precondition((0...2).contains(backoffLevel))
        self.context = context
        self.isLowPowerMode = isLowPowerMode
        self.backoffLevel = backoffLevel
    }

    func interval(for domain: SamplingDomain) -> Duration? {
        guard context != .disabled, context != .suspended else { return nil }
        guard !(context == .background && (domain == .diskIO || domain == .network)) else { return nil }

        let seconds: Double
        switch (context, isLowPowerMode, domain) {
        case (_, _, .capacity):
            seconds = 60
        case (.foreground, false, .cpu),
             (.foreground, false, .gpu),
             (.foreground, false, .memory),
             (.foreground, false, .diskIO),
             (.foreground, false, .network):
            seconds = 1
        case (.foreground, false, .temperature),
             (.foreground, false, .fans):
            seconds = 2
        case (.foreground, false, .optional):
            seconds = 2
        case (.foreground, true, .cpu),
             (.foreground, true, .gpu),
             (.foreground, true, .memory),
             (.foreground, true, .diskIO),
             (.foreground, true, .network):
            seconds = 2
        case (.foreground, true, .temperature),
             (.foreground, true, .fans),
             (.foreground, true, .optional):
            seconds = 4
        case (.background, false, .cpu),
             (.background, false, .memory):
            seconds = 5
        case (.background, false, .gpu),
             (.background, false, .temperature),
             (.background, false, .fans),
             (.background, false, .optional):
            seconds = 10
        case (.background, true, .cpu),
             (.background, true, .memory):
            seconds = 10
        case (.background, true, .gpu),
             (.background, true, .temperature),
             (.background, true, .fans),
             (.background, true, .optional):
            seconds = 20
        case (.disabled, _, _), (.suspended, _, _),
             (.background, _, .diskIO), (.background, _, .network):
            return nil
        }

        guard !(backoffLevel == 2 && domain == .optional) else { return nil }

        let multiplier: Double
        switch backoffLevel {
        case 0:
            multiplier = 1
        case 1:
            multiplier = [.gpu, .temperature, .fans, .optional].contains(domain) ? 2 : 1
        case 2:
            multiplier = 2
        default:
            preconditionFailure("Unsupported backoff level")
        }
        return .seconds(seconds * multiplier)
    }
}

struct SamplingBackoffState: Equatable, Sendable {
    private(set) var level = 0
    private var consecutiveOverBudget = 0
    private var stableSince: ContinuousClock.Instant?

    mutating func record(
        overBudget: Bool,
        at instant: ContinuousClock.Instant
    ) {
        if overBudget {
            stableSince = nil
            consecutiveOverBudget += 1
            if consecutiveOverBudget == 3 {
                level = min(level + 1, 2)
                consecutiveOverBudget = 0
            }
            return
        }

        consecutiveOverBudget = 0
        if stableSince == nil {
            stableSince = instant
        }
        if let stableSince, instant - stableSince >= .seconds(30), level > 0 {
            level -= 1
            self.stableSince = instant
        }
    }
}
