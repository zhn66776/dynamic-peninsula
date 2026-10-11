import XCTest
@testable import Dynamic_Peninsula

final class CPUDeltaCalculatorTests: XCTestCase {
    private let idle = CPUCoreTicks(user: 0, system: 0, nice: 0, idle: 100)
    private let zero = CPUCoreTicks(user: 0, system: 0, nice: 0, idle: 0)

    func testFirstSampleHasNoDelta() {
        XCTAssertNil(CPUDeltaCalculator.calculate(previous: nil, current: [idle], grouping: nil))
    }

    func testIdleAndBusyAreNormalizedToOneHundredPercentScale() throws {
        let idleResult = try result(previous: [zero], current: [idle])
        XCTAssertEqual(idleResult.totalPercent, 0, accuracy: 0.0001)

        let busy = CPUCoreTicks(user: 40, system: 30, nice: 30, idle: 0)
        let busyResult = try result(previous: [zero], current: [busy])
        XCTAssertEqual(busyResult.totalPercent, 100, accuracy: 0.0001)
    }

    func testMixedTicksAndMultipleCoresUseWeightedAggregate() throws {
        let first = CPUCoreTicks(user: 40, system: 20, nice: 10, idle: 30)
        let second = CPUCoreTicks(user: 10, system: 10, nice: 0, idle: 80)
        let value = try result(previous: [zero, zero], current: [first, second])
        XCTAssertEqual(value.totalPercent, 45, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(value.totalPercent, 100)
    }

    func testPerformanceAndEfficiencyGroupsUseExplicitIndices() throws {
        let current = [
            CPUCoreTicks(user: 10, system: 0, nice: 0, idle: 90),
            CPUCoreTicks(user: 20, system: 0, nice: 0, idle: 80),
            CPUCoreTicks(user: 90, system: 0, nice: 0, idle: 10),
            CPUCoreTicks(user: 80, system: 0, nice: 0, idle: 20)
        ]
        let grouping = CPUCoreGrouping(performanceIndices: [2, 3], efficiencyIndices: [0, 1])
        let value = try result(previous: Array(repeating: zero, count: 4), current: current, grouping: grouping)
        XCTAssertEqual(try XCTUnwrap(value.performancePercent), 85, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(value.efficiencyPercent), 15, accuracy: 0.0001)
    }

    func testNoTickGrowthAndCounterResetDiscardSample() {
        XCTAssertNil(CPUDeltaCalculator.calculate(previous: [idle], current: [idle], grouping: nil))
        let reset = CPUCoreTicks(user: 1, system: 1, nice: 1, idle: 1)
        XCTAssertNil(CPUDeltaCalculator.calculate(previous: [idle], current: [reset], grouping: nil))
    }

    func testUInt32TickWrapUsesUnsignedDelta() throws {
        let previous = CPUCoreTicks(
            user: UInt32.max - 9,
            system: UInt32.max - 19,
            nice: UInt32.max - 29,
            idle: UInt32.max - 39
        )
        let current = CPUCoreTicks(user: 10, system: 20, nice: 30, idle: 40)
        let value = try result(previous: [previous], current: [current])
        XCTAssertEqual(value.totalPercent, 60, accuracy: 0.0001)
    }

    func testOneIdleOfflineCoreDoesNotHideOtherCoreDelta() throws {
        let active = CPUCoreTicks(user: 50, system: 0, nice: 0, idle: 50)
        let value = try result(previous: [zero, zero], current: [zero, active])
        XCTAssertEqual(value.totalPercent, 50, accuracy: 0.0001)
    }

    func testCoreCountMismatchReturnsTypedDiagnostic() {
        let result = CPUDeltaCalculator.calculate(previous: [zero], current: [idle, idle], grouping: nil)
        XCTAssertEqual(
            result,
            .failure(.malformedValue(domain: "cpu", field: "coreCount"))
        )
    }

    func testIncompleteCoreGroupingDoesNotGuessMissingIndices() throws {
        let grouping = CPUCoreGrouping(performanceIndices: [1], efficiencyIndices: [0])
        let value = try result(
            previous: [zero, zero, zero],
            current: [idle, idle, idle],
            grouping: grouping
        )
        XCTAssertNil(value.performancePercent)
        XCTAssertNil(value.efficiencyPercent)
    }

    private func result(
        previous: [CPUCoreTicks],
        current: [CPUCoreTicks],
        grouping: CPUCoreGrouping? = nil
    ) throws -> CPUDeltaResult {
        let result = try XCTUnwrap(CPUDeltaCalculator.calculate(
            previous: previous,
            current: current,
            grouping: grouping
        ))
        return try result.get()
    }
}
