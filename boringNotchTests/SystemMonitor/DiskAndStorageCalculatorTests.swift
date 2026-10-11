import XCTest
@testable import Dynamic_Peninsula

final class DiskAndStorageCalculatorTests: XCTestCase {
    func testDiskBindingFailureUsesTenSecondRetryAndResetRebindsImmediately() {
        let clock = ContinuousClock()
        let start = clock.now
        var retry = DiskBindingRetryState()
        XCTAssertTrue(retry.shouldAttempt(at: start))
        retry.recordFailure(at: start)
        XCTAssertFalse(retry.shouldAttempt(at: start.advanced(by: .seconds(9))))
        XCTAssertTrue(retry.shouldAttempt(at: start.advanced(by: .seconds(10))))
        retry.recordFailure(at: start.advanced(by: .seconds(10)))
        retry.reset()
        XCTAssertTrue(retry.shouldAttempt(at: start.advanced(by: .seconds(10))))
        retry.recordFailure(at: start)
        retry.recordSuccess()
        XCTAssertTrue(retry.shouldAttempt(at: start))
    }

    func testSystemDiskRequiresBothWholeAndInternalIdentity() {
        XCTAssertTrue(SystemDiskIdentityValidator.isInternalWhole(mediaWhole: true, deviceInternal: true))
        XCTAssertFalse(SystemDiskIdentityValidator.isInternalWhole(mediaWhole: false, deviceInternal: true))
        XCTAssertFalse(SystemDiskIdentityValidator.isInternalWhole(mediaWhole: true, deviceInternal: false))
        XCTAssertFalse(SystemDiskIdentityValidator.isInternalWhole(mediaWhole: true, deviceInternal: nil))
    }

    func testElapsedTimeAndIndependentReadWriteRates() throws {
        let clock = ContinuousClock()
        let start = clock.now
        var calculator = DiskRateCalculator()
        XCTAssertNil(calculator.sample(counters: .init(readBytes: 100, writtenBytes: 200), at: start))
        let oneSecond = try XCTUnwrap(calculator.sample(
            counters: .init(readBytes: 1_124, writtenBytes: 2_248),
            at: start.advanced(by: .seconds(1))
        ))
        XCTAssertEqual(oneSecond.readBytesPerSecond, 1_024, accuracy: 0.001)
        XCTAssertEqual(oneSecond.writeBytesPerSecond, 2_048, accuracy: 0.001)

        let twoSeconds = try XCTUnwrap(calculator.sample(
            counters: .init(readBytes: 3_172, writtenBytes: 3_272),
            at: start.advanced(by: .seconds(3))
        ))
        XCTAssertEqual(twoSeconds.readBytesPerSecond, 1_024, accuracy: 0.001)
        XCTAssertEqual(twoSeconds.writeBytesPerSecond, 512, accuracy: 0.001)
    }

    func testCounterResetRebuildsBaselineAndClearsAverage() throws {
        let clock = ContinuousClock()
        let start = clock.now
        var calculator = DiskRateCalculator()
        _ = calculator.sample(counters: .init(readBytes: 100, writtenBytes: 100), at: start)
        _ = calculator.sample(counters: .init(readBytes: 200, writtenBytes: 200), at: start.advanced(by: .seconds(1)))
        XCTAssertNil(calculator.sample(
            counters: .init(readBytes: 1, writtenBytes: 1),
            at: start.advanced(by: .seconds(2))
        ))
        let result = try XCTUnwrap(calculator.sample(
            counters: .init(readBytes: 51, writtenBytes: 101),
            at: start.advanced(by: .seconds(3))
        ))
        XCTAssertEqual(result.smoothedReadBytesPerSecond, 50, accuracy: 0.001)
        XCTAssertEqual(result.smoothedWriteBytesPerSecond, 100, accuracy: 0.001)
    }

    func testResetMakesNextForegroundSampleBaselineOnly() {
        let clock = ContinuousClock()
        var calculator = DiskRateCalculator()
        _ = calculator.sample(counters: .init(readBytes: 1, writtenBytes: 1), at: clock.now)
        calculator.reset()
        XCTAssertNil(calculator.sample(counters: .init(readBytes: 1_000, writtenBytes: 1_000), at: clock.now))
    }

    func testMovingAverageKeepsOnlyThreeMostRecentSamples() throws {
        let clock = ContinuousClock()
        let start = clock.now
        var calculator = DiskRateCalculator()
        var counter = UInt64(0)
        _ = calculator.sample(counters: .init(readBytes: counter, writtenBytes: counter), at: start)
        for second in 1...4 {
            counter += UInt64(second * 100)
            let result = try XCTUnwrap(calculator.sample(
                counters: .init(readBytes: counter, writtenBytes: counter),
                at: start.advanced(by: .seconds(Double(second)))
            ))
            if second == 4 {
                XCTAssertEqual(result.smoothedReadBytesPerSecond, 300, accuracy: 0.001)
            }
        }
    }

    func testRateFormatterBoundaries() {
        let bytes = SystemMetricFormatter.rate(1_023)
        XCTAssertTrue(bytes.hasSuffix("B/s"))
        XCTAssertFalse(bytes.contains("KB/s"))
        XCTAssertEqual(SystemMetricFormatter.rate(1_024), "1.0 KB/s")
        XCTAssertEqual(SystemMetricFormatter.rate(1_048_576), "1.0 MB/s")
        XCTAssertEqual(SystemMetricFormatter.rate(1_073_741_824), "1.0 GB/s")
    }

    func testStorageCapacityUsesIntegerGibibytes() {
        XCTAssertEqual(SystemMetricFormatter.storageCapacity(nil), "—")
        XCTAssertEqual(
            SystemMetricFormatter.storageCapacity(UInt64(92.71 * 1_073_741_824)),
            "93 GB"
        )
    }

    func testStorageThresholdFloorsPercentagesAndBoundaries() {
        let gib = StorageThresholdCalculator.gibibyte
        XCTAssertEqual(StorageThresholdCalculator.health(totalBytes: 100 * gib, availableBytes: 10 * gib), .warning)
        XCTAssertEqual(StorageThresholdCalculator.health(totalBytes: 100 * gib, availableBytes: 5 * gib), .critical)
        XCTAssertEqual(StorageThresholdCalculator.health(totalBytes: 1_000 * gib, availableBytes: 50 * gib), .warning)
        XCTAssertEqual(StorageThresholdCalculator.health(totalBytes: 1_000 * gib, availableBytes: 20 * gib), .critical)
        XCTAssertEqual(StorageThresholdCalculator.health(totalBytes: nil, availableBytes: 1), .unavailable)
        XCTAssertEqual(StorageThresholdCalculator.health(totalBytes: 10, availableBytes: 11), .unavailable)
    }
}
