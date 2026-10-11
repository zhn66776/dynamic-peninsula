import XCTest
@testable import Dynamic_Peninsula

final class FixedRingBufferAndSamplingPolicyTests: XCTestCase {
    func testRingBufferOrderCapacityAndPersistenceAcrossReads() {
        var buffer = FixedRingBuffer<Int>(capacity: 60)
        XCTAssertEqual(buffer.elements, [])
        for value in 0..<60 { buffer.append(value) }
        XCTAssertEqual(buffer.elements, Array(0..<60))
        XCTAssertEqual(buffer.elements, Array(0..<60))
        buffer.append(60)
        XCTAssertEqual(buffer.count, 60)
        XCTAssertEqual(buffer.elements, Array(1...60))
    }

    func testRingBufferIsNotClearedByLeavingAndReturning() {
        var history = SystemMonitorHistory()
        history.cpu.append(.init(id: 1, timestamp: Date(), value: 12))
        let retained = history
        XCTAssertEqual(retained.cpu.count, 1)
    }

    func testHistoryEnforcesBothSixtyPointsAndSixtySecondWindow() {
        let now = Date()
        var history = SystemMonitorHistory()
        history.cpu.append(.init(id: 0, timestamp: now.addingTimeInterval(-61), value: 1))
        for id in 1...61 {
            history.cpu.append(.init(id: UInt64(id), timestamp: now, value: Double(id)))
        }
        history.trim(before: now.addingTimeInterval(-60))
        XCTAssertEqual(history.cpu.count, 60)
        XCTAssertEqual(history.cpu.elements.first?.id, 2)
        XCTAssertEqual(history.cpu.elements.last?.id, 61)
    }

    func testForegroundAndBackgroundIntervals() {
        let foreground = SystemMonitorSamplingPolicy(context: .foreground, isLowPowerMode: false, backoffLevel: 0)
        XCTAssertEqual(foreground.interval(for: .cpu), .seconds(1))
        XCTAssertEqual(foreground.interval(for: .temperature), .seconds(2))
        XCTAssertEqual(foreground.interval(for: .capacity), .seconds(60))

        let background = SystemMonitorSamplingPolicy(context: .background, isLowPowerMode: false, backoffLevel: 0)
        XCTAssertEqual(background.interval(for: .cpu), .seconds(5))
        XCTAssertEqual(background.interval(for: .gpu), .seconds(10))
        XCTAssertNil(background.interval(for: .diskIO))
    }

    func testLowPowerDisabledSuspendedAndBackoff() {
        let lowPower = SystemMonitorSamplingPolicy(context: .foreground, isLowPowerMode: true, backoffLevel: 0)
        XCTAssertEqual(lowPower.interval(for: .cpu), .seconds(2))
        XCTAssertEqual(lowPower.interval(for: .fans), .seconds(4))

        for context in [SamplingContext.disabled, .suspended] {
            let policy = SystemMonitorSamplingPolicy(context: context, isLowPowerMode: false, backoffLevel: 0)
            for domain in SamplingDomain.allCases { XCTAssertNil(policy.interval(for: domain)) }
        }

        let levelOne = SystemMonitorSamplingPolicy(context: .foreground, isLowPowerMode: false, backoffLevel: 1)
        XCTAssertEqual(levelOne.interval(for: .cpu), .seconds(1))
        XCTAssertEqual(levelOne.interval(for: .gpu), .seconds(2))
        let levelTwo = SystemMonitorSamplingPolicy(context: .foreground, isLowPowerMode: false, backoffLevel: 2)
        XCTAssertEqual(levelTwo.interval(for: .cpu), .seconds(2))
        XCTAssertNil(levelTwo.interval(for: .optional))
    }

    func testBackoffRequiresThreeOverBudgetSamplesAndRecoversOneLevelPerThirtySeconds() {
        let clock = ContinuousClock()
        let start = clock.now
        var state = SamplingBackoffState()
        state.record(overBudget: true, at: start)
        state.record(overBudget: true, at: start)
        XCTAssertEqual(state.level, 0)
        state.record(overBudget: true, at: start)
        XCTAssertEqual(state.level, 1)
        for _ in 0..<3 { state.record(overBudget: true, at: start) }
        XCTAssertEqual(state.level, 2)
        state.record(overBudget: false, at: start)
        state.record(overBudget: false, at: start.advanced(by: .seconds(30)))
        XCTAssertEqual(state.level, 1)
        state.record(overBudget: false, at: start.advanced(by: .seconds(60)))
        XCTAssertEqual(state.level, 0)
    }
}
