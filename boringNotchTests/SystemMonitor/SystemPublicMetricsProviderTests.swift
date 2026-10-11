import XCTest
@testable import Dynamic_Peninsula

final class SystemPublicMetricsProviderTests: XCTestCase {
    func testCurrentMachinePublicMetrics() async throws {
        let provider = SystemPublicMetricsProvider()
        _ = await provider.sample(domains: [.cpu, .diskIO], at: ContinuousClock().now)
        try await Task.sleep(for: .milliseconds(100))
        let snapshot = await provider.sample(
            domains: [.cpu, .memory, .storage, .diskIO, .thermal],
            at: ContinuousClock().now
        )

        let cpu = try XCTUnwrap(snapshot.cpu).get()
        let total = try XCTUnwrap(cpu.totalPercent.value)
        XCTAssertTrue((0...100).contains(total))
        XCTAssertGreaterThan(cpu.logicalCoreCount, 0)
        XCTAssertEqual(cpu.performanceCoreCount.map { $0 + (cpu.efficiencyCoreCount ?? 0) }, cpu.logicalCoreCount)

        let memory = try XCTUnwrap(snapshot.memory).get()
        XCTAssertGreaterThan(memory.totalBytes, 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(memory.usedBytes), memory.totalBytes)

        let storage = try XCTUnwrap(snapshot.capacity).get()
        XCTAssertGreaterThan(try XCTUnwrap(storage.totalBytes), 0)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(storage.availableForImportantUsageBytes),
            try XCTUnwrap(storage.totalBytes)
        )
        let disk = try XCTUnwrap(snapshot.diskIO).get()
        if let read = disk.instantaneousReadBytesPerSecond,
           let write = disk.instantaneousWriteBytesPerSecond {
            XCTAssertGreaterThanOrEqual(read, 0)
            XCTAssertGreaterThanOrEqual(write, 0)
        }
        XCTAssertNotNil(snapshot.thermal)
    }
}
