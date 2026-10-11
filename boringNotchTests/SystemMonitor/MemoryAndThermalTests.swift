import Foundation
import XCTest
@testable import Dynamic_Peninsula

final class MemoryAndThermalTests: XCTestCase {
    func testPageCountsBecomeBytesWithoutCompressedOrFileBackedDoubleCounting() throws {
        let pages = VMMemoryPageCounts(
            free: 10,
            active: 100,
            inactive: 50,
            speculative: 10,
            wired: 20,
            purgeable: 10,
            fileBacked: 30,
            compressed: 5
        )
        let result = try MemoryMetricsCalculator.calculate(
            pages: pages,
            pageSize: 4_096,
            totalBytes: 1_000_000
        ).get()
        XCTAssertEqual(result.used, 1_000_000 - (10 + 40) * 4_096)
        XCTAssertEqual(result.cached, 40 * 4_096)
        XCTAssertEqual(result.compressed, 5 * 4_096)
    }

    func testImpossibleCompositionReturnsTypedFailure() {
        let pages = VMMemoryPageCounts(
            free: 0,
            active: 1,
            inactive: 1,
            speculative: 0,
            wired: 0,
            purgeable: 2,
            fileBacked: 2,
            compressed: 0
        )
        XCTAssertEqual(
            MemoryMetricsCalculator.calculate(pages: pages, pageSize: 4_096, totalBytes: 100_000),
            .failure(.malformedValue(domain: "memory", field: "pageComposition"))
        )
    }

    func testPressureEnumDoesNotInferFromUsedPercentage() {
        let lowUsed = MemoryMetrics(
            pressure: .critical,
            usedBytes: 1,
            totalBytes: 1_000,
            cachedBytes: 0,
            compressedBytes: 0,
            swapUsedBytes: 0
        )
        let highUsed = MemoryMetrics(
            pressure: .unavailable,
            usedBytes: 999,
            totalBytes: 1_000,
            cachedBytes: 0,
            compressedBytes: 0,
            swapUsedBytes: 0
        )
        XCTAssertEqual(lowUsed.pressure, .critical)
        XCTAssertEqual(highUsed.pressure, .unavailable)
    }

    func testSystemMemoryPressureEventsMapDirectly() {
        XCTAssertEqual(MemoryPressureLevelMapper.level(for: .normal), .normal)
        XCTAssertEqual(MemoryPressureLevelMapper.level(for: .warning), .warning)
        XCTAssertEqual(MemoryPressureLevelMapper.level(for: .critical), .critical)
        XCTAssertEqual(MemoryPressureLevelMapper.level(for: [.normal, .critical]), .critical)
        XCTAssertNil(MemoryPressureLevelMapper.level(for: []))
    }

    func testThermalStateMapping() {
        XCTAssertEqual(SystemPublicMetricsProvider.thermalLevel(.nominal), .nominal)
        XCTAssertEqual(SystemPublicMetricsProvider.thermalLevel(.fair), .fair)
        XCTAssertEqual(SystemPublicMetricsProvider.thermalLevel(.serious), .serious)
        XCTAssertEqual(SystemPublicMetricsProvider.thermalLevel(.critical), .critical)
    }
}
