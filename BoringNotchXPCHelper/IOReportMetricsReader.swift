import CoreFoundation
import Foundation

enum IOReportMetricsReaderError: Error {
    case subscriptionUnavailable
    case sampleUnavailable
    case channelUnavailable
    case malformedResidency
}

final class IOReportMetricsReader {
    private typealias CopyChannels = @convention(c) (
        CFString, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?, CFDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?
    ) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (
        OpaquePointer, CFMutableDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (
        CFDictionary, CFDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (
        CFDictionary, Int32
    ) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let handle: UnsafeMutableRawPointer?
    private let subscription: OpaquePointer?
    private let subscribedChannels: CFMutableDictionary?
    private let createSamples: CreateSamples?
    private let createDelta: CreateDelta?
    private let channelGroup: ChannelString?
    private let channelSubgroup: ChannelString?
    private let channelName: ChannelString?
    private let channelUnit: ChannelString?
    private let stateCount: StateCount?
    private let stateName: StateName?
    private let stateResidency: StateResidency?

    let isAvailable: Bool
    let temperatureStatusReason: String

    init() {
        let paths = [
            "/usr/lib/libIOReport.dylib",
            "/System/Library/PrivateFrameworks/IOReport.framework/Versions/A/IOReport",
            "/System/Library/PrivateFrameworks/IOReport.framework/IOReport"
        ]
        var loaded: UnsafeMutableRawPointer?
        for path in paths where loaded == nil {
            loaded = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
        }
        handle = loaded

        let copyChannels: CopyChannels? = Self.symbol(
            loaded, "IOReportCopyChannelsInGroup", as: CopyChannels.self
        )
        let createSubscription: CreateSubscription? = Self.symbol(
            loaded, "IOReportCreateSubscription", as: CreateSubscription.self
        )
        createSamples = Self.symbol(loaded, "IOReportCreateSamples", as: CreateSamples.self)
        createDelta = Self.symbol(loaded, "IOReportCreateSamplesDelta", as: CreateDelta.self)
        channelGroup = Self.symbol(loaded, "IOReportChannelGetGroup", as: ChannelString.self)
        channelSubgroup = Self.symbol(loaded, "IOReportChannelGetSubGroup", as: ChannelString.self)
        channelName = Self.symbol(loaded, "IOReportChannelGetChannelName", as: ChannelString.self)
        channelUnit = Self.symbol(loaded, "IOReportChannelGetUnitLabel", as: ChannelString.self)
        stateCount = Self.symbol(loaded, "IOReportStateGetCount", as: StateCount.self)
        stateName = Self.symbol(loaded, "IOReportStateGetNameForIndex", as: StateName.self)
        stateResidency = Self.symbol(loaded, "IOReportStateGetResidency", as: StateResidency.self)

        if let copyChannels,
           let createSubscription,
           let channels = copyChannels(
               "GPU Stats" as CFString,
               "GPU Performance States" as CFString,
               0, 0, 0
           )?.takeRetainedValue() {
            var subscribed: Unmanaged<CFMutableDictionary>?
            subscription = createSubscription(nil, channels, &subscribed, 0, nil)
            subscribedChannels = subscribed?.takeRetainedValue()
        } else {
            subscription = nil
            subscribedChannels = nil
        }

        isAvailable = subscription != nil
            && subscribedChannels != nil
            && createSamples != nil
            && createDelta != nil
            && channelGroup != nil
            && channelSubgroup != nil
            && channelName != nil
            && channelUnit != nil
            && stateCount != nil
            && stateName != nil
            && stateResidency != nil

        // Phase 1 found temperature channels with no unit label on this M3.
        // Without a verified encoding they are catalog evidence only.
        temperatureStatusReason = isAvailable ? "temperatureUnitUnverified" : "symbolsUnavailable"
    }

    deinit {
        if let subscription {
            Unmanaged<AnyObject>
                .fromOpaque(UnsafeRawPointer(subscription))
                .release()
        }
        if let handle { dlclose(handle) }
    }

    func readGPUUtilizationPercent(window: TimeInterval = 0.1) throws -> Double {
        guard isAvailable,
              let subscription,
              let subscribedChannels,
              let createSamples,
              let createDelta,
              let channelGroup,
              let channelSubgroup,
              let channelName,
              let channelUnit,
              let stateCount,
              let stateName,
              let stateResidency else {
            throw IOReportMetricsReaderError.subscriptionUnavailable
        }
        guard let first = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
        else { throw IOReportMetricsReaderError.sampleUnavailable }
        Thread.sleep(forTimeInterval: max(0, window))
        guard let second = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue(),
              let delta = createDelta(first, second, nil)?.takeRetainedValue(),
              let entries = (delta as NSDictionary)["IOReportChannels"] as? NSArray else {
            throw IOReportMetricsReaderError.sampleUnavailable
        }

        for case let dictionary as NSDictionary in entries {
            let channel = unsafeBitCast(dictionary, to: CFDictionary.self)
            let group = channelGroup(channel)?.takeUnretainedValue() as String?
            let subgroup = channelSubgroup(channel)?.takeUnretainedValue() as String?
            let name = channelName(channel)?.takeUnretainedValue() as String?
            let unit = channelUnit(channel)?.takeUnretainedValue() as String?
            guard group == "GPU Stats",
                  subgroup == "GPU Performance States",
                  name == "GPUPH",
                  unit == "24Mticks" else { continue }

            let count = Int(stateCount(channel))
            guard count > 0 else { throw IOReportMetricsReaderError.malformedResidency }
            var total: Double = 0
            var active: Double = 0
            for index in 0..<count {
                let residency = Double(stateResidency(channel, Int32(index)))
                guard residency >= 0 else {
                    throw IOReportMetricsReaderError.malformedResidency
                }
                let state = stateName(channel, Int32(index))?.takeUnretainedValue() as String? ?? ""
                total += residency
                if !["IDLE", "DOWN", "OFF"].contains(state) {
                    active += residency
                }
            }
            guard total > 0 else { throw IOReportMetricsReaderError.malformedResidency }
            let percent = active / total * 100
            guard percent.isFinite, (0...100).contains(percent) else {
                throw IOReportMetricsReaderError.malformedResidency
            }
            return percent
        }
        throw IOReportMetricsReaderError.channelUnavailable
    }

    private static func symbol<T>(
        _ handle: UnsafeMutableRawPointer?,
        _ name: String,
        as type: T.Type
    ) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}
