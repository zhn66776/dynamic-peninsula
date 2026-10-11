import Foundation
import IOKit
import Metal
import XCTest
@testable import Dynamic_Peninsula

final class XPCContractAndFixtureTests: XCTestCase {
    func testLiveHelperReturnsInitialMemoryPressureFallback() async throws {
        let snapshot = try await XPCHelperClient.shared.systemMonitorSnapshot(
            request: SystemMonitorXPCRequest(
                includeGPU: false,
                includeTemperatures: false,
                includeFans: false,
                includeFrequencyAndPower: false,
                includeMemoryPressure: true
            )
        )
        XCTAssertTrue(["normal", "warning", "critical"].contains(snapshot.memoryPressureLevel))
        XCTAssertTrue(snapshot.diagnostics.contains {
            $0.domain == "memoryPressure" && $0.status == "available"
        })
    }

    private struct HardwareFixture: Decodable {
        struct GPU: Decodable {
            let device: Double?
            let renderer: Double?
            let tiler: Double?
        }

        let schemaVersion: Int
        let chipFamily: String
        let performanceIndices: [Int]
        let efficiencyIndices: [Int]
        let hasFanHardware: Bool
        let fans: [Double]
        let gpu: GPU?
        let cpuTemperatures: [Double]?
        let gpuTemperatures: [Double]?
    }

    func testM1ThroughM5FanfulAndFanlessFixturesDecode() throws {
        let names = [
            "m1-air-fanless", "m1-pro-fanful", "m2-air-fanless",
            "m2-pro-fanful", "m3-pro-current-machine", "m4-pro", "m5-pro"
        ]
        let fixtures = try names.map(loadFixture)
        XCTAssertEqual(Set(fixtures.map(\.chipFamily)), Set(["M1", "M2", "M3", "M4", "M5"]))
        XCTAssertTrue(fixtures.contains { !$0.hasFanHardware && $0.fans.isEmpty })
        XCTAssertTrue(fixtures.contains { $0.hasFanHardware && $0.fans.contains(0) })
        for fixture in fixtures {
            let grouping = CPUCoreGrouping(
                performanceIndices: fixture.performanceIndices,
                efficiencyIndices: fixture.efficiencyIndices
            )
            let coreCount = try XCTUnwrap(
                (fixture.performanceIndices + fixture.efficiencyIndices).max().map { $0 + 1 }
            )
            XCTAssertTrue(grouping.isValid(forCoreCount: coreCount), fixture.chipFamily)

            let zero = CPUCoreTicks(user: 0, system: 0, nice: 0, idle: 0)
            var current = Array(repeating: zero, count: coreCount)
            for index in fixture.efficiencyIndices {
                current[index] = CPUCoreTicks(user: 20, system: 0, nice: 0, idle: 80)
            }
            for index in fixture.performanceIndices {
                current[index] = CPUCoreTicks(user: 80, system: 0, nice: 0, idle: 20)
            }
            let delta = try XCTUnwrap(
                CPUDeltaCalculator.calculate(
                    previous: Array(repeating: zero, count: coreCount),
                    current: current,
                    grouping: grouping
                )
            ).get()
            XCTAssertEqual(try XCTUnwrap(delta.performancePercent), 80, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(delta.efficiencyPercent), 20, accuracy: 0.0001)

            let fans = SensorPayloadSanitizer.fans(
                hasFanHardware: fixture.hasFanHardware,
                rpmValues: fixture.fans
            )
            XCTAssertEqual(
                fans.availability,
                fixture.hasFanHardware ? (fixture.fans.isEmpty ? .unavailable : .available) : .unavailable
            )
            if fixture.hasFanHardware, fixture.fans.contains(0) {
                XCTAssertTrue(fans.metrics.contains { $0.rpm == 0 })
            }

            let device = SensorPayloadSanitizer.utilizationReading(
                fixture.gpu?.device,
                sampledAt: Date(timeIntervalSinceReferenceDate: 0)
            )
            XCTAssertEqual(device.availability, fixture.gpu?.device == nil ? .unavailable : .available)
            let renderer = SensorPayloadSanitizer.utilizationReading(
                fixture.gpu?.renderer,
                sampledAt: Date(timeIntervalSinceReferenceDate: 0)
            )
            let tiler = SensorPayloadSanitizer.utilizationReading(
                fixture.gpu?.tiler,
                sampledAt: Date(timeIntervalSinceReferenceDate: 0)
            )
            if fixture.gpu?.renderer == nil { XCTAssertEqual(renderer.availability, .unavailable) }
            if fixture.gpu?.tiler == nil { XCTAssertEqual(tiler.availability, .unavailable) }

            let cpuTemperature = SensorPayloadSanitizer.temperatureReading(
                fixture.cpuTemperatures,
                sampledAt: Date(timeIntervalSinceReferenceDate: 0)
            )
            let gpuTemperature = SensorPayloadSanitizer.temperatureReading(
                fixture.gpuTemperatures,
                sampledAt: Date(timeIntervalSinceReferenceDate: 0)
            )
            XCTAssertEqual(
                cpuTemperature.availability,
                fixture.cpuTemperatures == nil ? .unavailable : .available
            )
            XCTAssertEqual(
                gpuTemperature.availability,
                fixture.gpuTemperatures == nil ? .unavailable : .available
            )
        }
    }

    func testSensorValidationRejectsAbnormalValuesAndUnknownKeys() throws {
        let invalid = try loadFixture("invalid-sensors")
        XCTAssertEqual(invalid.chipFamily, "Unknown")
        XCTAssertNil(SensorValueValidator.utilization(invalid.gpu?.device))
        XCTAssertNil(SensorValueValidator.utilization(invalid.gpu?.renderer))
        XCTAssertNil(SensorValueValidator.utilization(.nan))
        XCTAssertNil(SensorValueValidator.utilization(.infinity))
        XCTAssertNil(SensorValueValidator.temperature(invalid.cpuTemperatures?.first))
        XCTAssertNil(SensorValueValidator.temperature(invalid.gpuTemperatures?.first))
        XCTAssertNil(SensorValueValidator.fanRPM(invalid.fans.first))
        XCTAssertEqual(SensorValueValidator.fanRPM(0), 0)
        XCTAssertEqual(SensorValueValidator.temperatureDomain(for: "Tp01"), .cpu)
        XCTAssertEqual(SensorValueValidator.temperatureDomain(for: "Te12"), .cpu)
        XCTAssertEqual(SensorValueValidator.temperatureDomain(for: "Tg03"), .gpu)
        XCTAssertNil(SensorValueValidator.temperatureDomain(for: "TB0T"))
        XCTAssertEqual(
            SensorPayloadSanitizer.utilizationReading(invalid.gpu?.device, sampledAt: Date()).availability,
            .failed
        )
        XCTAssertEqual(
            SensorPayloadSanitizer.temperatureReading(invalid.cpuTemperatures, sampledAt: Date()).availability,
            .failed
        )
        XCTAssertEqual(
            SensorPayloadSanitizer.fans(
                hasFanHardware: invalid.hasFanHardware,
                rpmValues: invalid.fans
            ).availability,
            .failed
        )
    }

    func testRequestRoundTripAndWrongSchema() throws {
        let request = SystemMonitorXPCRequest(
            includeGPU: true,
            includeTemperatures: false,
            includeFans: true,
            includeFrequencyAndPower: false
        )
        XCTAssertEqual(try SystemMonitorXPCRequest.decode(from: request.encoded()), request)

        let wrong = SystemMonitorXPCRequest(
            schemaVersion: 2,
            includeGPU: true,
            includeTemperatures: true,
            includeFans: true,
            includeFrequencyAndPower: false
        )
        XCTAssertThrowsError(try SystemMonitorXPCRequest.decode(from: wrong.encoded())) { error in
            XCTAssertEqual(
                error as? SystemMetricsProviderError,
                .schemaMismatch(expected: 1, actual: 2)
            )
        }
    }

    func testAvailableReadingCannotDecodeWithoutValue() {
        let json = """
        {"availability":"available","source":"mach","sampledAt":0}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(MetricReading<Double>.self, from: Data(json.utf8))
        )
    }

    func testSnapshotDecodesMissingOptionalDetailsAndUnknownFields() throws {
        let json = """
        {
          "schemaVersion": 1,
          "sampledAt": 0,
          "capabilities": {
            "isAppleSilicon": true,
            "chipFamily": "M3",
            "hasFanHardware": true,
            "supportsAGXUtilization": true,
            "supportsCPUTemperature": false,
            "supportsGPUTemperature": false,
            "supportsIOReport": false,
            "supportsAppleSMC": false,
            "futureCapability": true
          },
          "gpu": null,
          "temperatures": null,
          "fans": [],
          "diagnostics": [],
          "futureTopLevel": "ignored"
        }
        """
        let snapshot = try SystemMonitorXPCSnapshot.decode(from: Data(json.utf8))
        XCTAssertNil(snapshot.gpu)
        XCTAssertNil(snapshot.temperatures)
        XCTAssertThrowsError(try SystemMonitorXPCSnapshot.decode(from: Data("bad".utf8)))
        XCTAssertThrowsError(
            try SystemMonitorXPCSnapshot.decode(from: loadFixtureData("wrong-schema"))
        ) { error in
            XCTAssertEqual(
                error as? SystemMetricsProviderError,
                .schemaMismatch(expected: 1, actual: 2)
            )
        }
    }

    func testPrivateTimeoutFixtureRepresentsUnavailablePrivateDomains() throws {
        let fixture = try loadFixture("private-timeout")
        XCTAssertNil(fixture.gpu)
        XCTAssertNil(fixture.cpuTemperatures)
        XCTAssertNil(fixture.gpuTemperatures)
        XCTAssertEqual(
            SensorPayloadSanitizer.utilizationReading(fixture.gpu?.device, sampledAt: Date()).availability,
            .unavailable
        )
        XCTAssertEqual(
            SensorPayloadSanitizer.temperatureReading(fixture.cpuTemperatures, sampledAt: Date()).availability,
            .unavailable
        )
        XCTAssertEqual(
            SensorPayloadSanitizer.fans(
                hasFanHardware: fixture.hasFanHardware,
                rpmValues: fixture.fans
            ).availability,
            .unavailable
        )
    }

    func testProtocolSignaturesStayIdentical() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helper = try String(contentsOf: repository
            .appendingPathComponent("BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift"))
        let app = try String(contentsOf: repository
            .appendingPathComponent("boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift"))
        XCTAssertEqual(systemMonitorSignature(in: helper), systemMonitorSignature(in: app))
    }

    func testRequestGateRejectsOverlapUntilReplyArrives() async {
        let gate = SystemMonitorXPCRequestGate()
        let first = await gate.begin()
        let overlapping = await gate.begin()
        XCTAssertTrue(first)
        XCTAssertFalse(overlapping)
        await gate.end()
        let afterReply = await gate.begin()
        XCTAssertTrue(afterReply)
    }

    func testReplyStateTimesOutWithoutFabricatingResponse() async {
        do {
            _ = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SystemMonitorXPCSnapshot, Error>) in
                let state = SystemMonitorXPCReplyState(continuation: continuation)
                state.startTimeout(after: .milliseconds(10))
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? SystemMonitorXPCError, .timedOut)
        }
    }

    func testLiveHelperReturnsOnePartialFailureTolerantSnapshot() async throws {
        let directBefore = try XCTUnwrap(directAGXUtilization())
        let snapshot = try await XPCHelperClient.shared.systemMonitorSnapshot(
            request: SystemMonitorXPCRequest(
                includeGPU: true,
                includeTemperatures: true,
                includeFans: true,
                includeFrequencyAndPower: false
            )
        )
        let directAfter = try XCTUnwrap(directAGXUtilization())
        print(
            "PHASE4_LIVE sampledAt=\(snapshot.sampledAt.timeIntervalSince1970) "
                + "cpuMax=\(snapshot.temperatures?.cpuMaxCelsius ?? -1) "
                + "gpuMax=\(snapshot.temperatures?.gpuMaxCelsius ?? -1) "
                + "fan=\(snapshot.fans.first?.rpm ?? -1)"
        )
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertTrue(snapshot.capabilities.isAppleSilicon)
        XCTAssertEqual(snapshot.capabilities.chipFamily, "M3")
        XCTAssertTrue(snapshot.capabilities.supportsAGXUtilization)
        XCTAssertTrue(snapshot.capabilities.supportsIOReport)
        XCTAssertTrue(snapshot.capabilities.supportsAppleSMC)
        XCTAssertTrue(snapshot.capabilities.supportsCPUTemperature)
        XCTAssertTrue(snapshot.capabilities.supportsGPUTemperature)
        XCTAssertTrue(snapshot.capabilities.hasFanHardware)

        let gpu = try XCTUnwrap(snapshot.gpu)
        XCTAssertTrue((0...100).contains(try XCTUnwrap(gpu.utilizationPercent)))
        XCTAssertTrue((0...100).contains(try XCTUnwrap(gpu.rendererPercent)))
        XCTAssertTrue((0...100).contains(try XCTUnwrap(gpu.tilerPercent)))
        assertWithinAGXWindow(
            helper: try XCTUnwrap(gpu.utilizationPercent),
            before: directBefore.device,
            after: directAfter.device
        )
        assertWithinAGXWindow(
            helper: try XCTUnwrap(gpu.rendererPercent),
            before: directBefore.renderer,
            after: directAfter.renderer
        )
        assertWithinAGXWindow(
            helper: try XCTUnwrap(gpu.tilerPercent),
            before: directBefore.tiler,
            after: directAfter.tiler
        )
        XCTAssertNil(gpu.memoryBytes)
        XCTAssertTrue(snapshot.diagnostics.contains {
            $0.domain == "gpuMemory"
                && $0.status == "unsupported"
                && $0.reason == "unitUnverified"
        })

        let temperatures = try XCTUnwrap(snapshot.temperatures)
        XCTAssertTrue((-10...125).contains(try XCTUnwrap(temperatures.cpuMaxCelsius)))
        XCTAssertTrue((-10...125).contains(try XCTUnwrap(temperatures.gpuMaxCelsius)))
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(temperatures.cpuMinimumCelsius),
            try XCTUnwrap(temperatures.cpuMaxCelsius)
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(temperatures.gpuMinimumCelsius),
            try XCTUnwrap(temperatures.gpuMaxCelsius)
        )
        XCTAssertEqual(snapshot.fans.count, 1)
        XCTAssertGreaterThanOrEqual(snapshot.fans[0].rpm, 0)
        XCTAssertTrue(snapshot.diagnostics.contains { $0.domain == "gpu" && $0.status == "available" })
        XCTAssertTrue(snapshot.diagnostics.contains {
            $0.domain == "cpuTemperature" && $0.status == "available"
        })
        XCTAssertTrue(snapshot.diagnostics.contains {
            $0.domain == "gpuTemperature" && $0.status == "available"
        })
        XCTAssertTrue(snapshot.diagnostics.contains { $0.domain == "fans" && $0.status == "available" })

        var durations = [TimeInterval]()
        for _ in 0..<10 {
            let started = Date()
            let repeated = try await XPCHelperClient.shared.systemMonitorSnapshot(
                request: SystemMonitorXPCRequest(
                    includeGPU: true,
                    includeTemperatures: true,
                    includeFans: true,
                    includeFrequencyAndPower: false
                )
            )
            durations.append(Date().timeIntervalSince(started))
            XCTAssertNotNil(repeated.gpu?.utilizationPercent)
            XCTAssertNotNil(repeated.temperatures?.cpuMaxCelsius)
            XCTAssertNotNil(repeated.temperatures?.gpuMaxCelsius)
            XCTAssertTrue(repeated.capabilities.hasFanHardware)
        }
        XCTAssertLessThan(try XCTUnwrap(durations.max()), 0.8)
    }

    func testLiveGPURespondsToFourSecondSafeComputeLoad() async throws {
        let load = try ShortMetalComputeLoad()
        let loadTask = Task.detached { load.run(for: 4) }
        var during = [Double]()
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(500))
            let snapshot = try await XPCHelperClient.shared.systemMonitorSnapshot(
                request: SystemMonitorXPCRequest(
                    includeGPU: true,
                    includeTemperatures: false,
                    includeFans: false,
                    includeFrequencyAndPower: false
                )
            )
            during.append(try XCTUnwrap(snapshot.gpu?.utilizationPercent))
        }
        await loadTask.value
        let peak = try XCTUnwrap(during.max())
        XCTAssertGreaterThanOrEqual(peak, 70)

        try await Task.sleep(for: .seconds(2))
        let cooled = try await XPCHelperClient.shared.systemMonitorSnapshot(
            request: SystemMonitorXPCRequest(
                includeGPU: true,
                includeTemperatures: false,
                includeFans: false,
                includeFrequencyAndPower: false
            )
        )
        XCTAssertLessThan(try XCTUnwrap(cooled.gpu?.utilizationPercent), peak - 10)
    }

    private func loadFixture(_ name: String) throws -> HardwareFixture {
        try JSONDecoder().decode(HardwareFixture.self, from: loadFixtureData(name))
    }

    private func loadFixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func systemMonitorSignature(in source: String) -> String? {
        let lines = source.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.contains("func systemMonitorSnapshot(") }) else {
            return nil
        }
        return lines[start...min(start + 3, lines.count - 1)]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    private func directAGXUtilization() -> (device: Double, renderer: Double, tiler: Double)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            let ioClass = IORegistryEntryCreateCFProperty(
                service,
                "IOClass" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String
            guard ioClass?.localizedCaseInsensitiveContains("AGX") == true else { continue }
            guard let statistics = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any],
                  let device = statistics["Device Utilization %"] as? NSNumber,
                  let renderer = statistics["Renderer Utilization %"] as? NSNumber,
                  let tiler = statistics["Tiler Utilization %"] as? NSNumber else {
                return nil
            }
            return (device.doubleValue, renderer.doubleValue, tiler.doubleValue)
        }
    }

    private func assertWithinAGXWindow(
        helper: Double,
        before: Double,
        after: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            min(abs(helper - before), abs(helper - after)),
            5,
            "helper=\(helper), directBefore=\(before), directAfter=\(after)",
            file: file,
            line: line
        )
    }
}

private final class ShortMetalComputeLoad: @unchecked Sendable {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private let itemCount = 1_048_576

    init() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void phase4ShortSpin(
            device uint *output [[buffer(0)]],
            uint id [[thread_position_in_grid]]
        ) {
            uint value = id + 1;
            for (uint index = 0; index < 1024; ++index) {
                value = value * 1664525u + 1013904223u;
            }
            output[id] = value;
        }
        """, options: nil)
        pipeline = try device.makeComputePipelineState(
            function: try XCTUnwrap(library.makeFunction(name: "phase4ShortSpin"))
        )
        buffer = try XCTUnwrap(device.makeBuffer(
            length: itemCount * MemoryLayout<UInt32>.stride,
            options: .storageModePrivate
        ))
    }

    func run(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            autoreleasepool {
                let commandBuffer = queue.makeCommandBuffer()!
                let compute = commandBuffer.makeComputeCommandEncoder()!
                compute.setComputePipelineState(pipeline)
                compute.setBuffer(buffer, offset: 0, index: 0)
                compute.dispatchThreads(
                    MTLSize(width: itemCount, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: pipeline.threadExecutionWidth,
                        height: 1,
                        depth: 1
                    )
                )
                compute.endEncoding()
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
            }
        }
    }
}
