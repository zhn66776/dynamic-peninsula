import Foundation
import IOKit

// Minimal read-only AppleSMC layout adapted from GoodOlClint/swift-soc-metrics
// commit 7454da9c72d420e602e54fa07aa23885de574961. No write selector is defined.
private struct SMCKeyData {
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var limitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

enum AppleSMCReaderError: Error {
    case serviceNotFound
    case openFailed(Int32)
    case keyCountUnavailable
    case fanCountMalformed
    case readFailed(String)
}

struct AppleSMCTemperatureSample {
    let cpu: [Double]
    let gpu: [Double]
    let invalidCPUCount: Int
    let invalidGPUCount: Int
}

final class AppleSMCReader {
    private static let selector: UInt32 = 2
    private static let readKey: UInt8 = 5
    private static let keyByIndex: UInt8 = 8
    private static let keyInfo: UInt8 = 9
    private static let floatType = fourCC("flt ")

    private let connection: io_connect_t
    let catalog: SystemSensorCatalog

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw AppleSMCReaderError.serviceNotFound }
        var openedConnection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &openedConnection)
        IOObjectRelease(service)
        guard result == kIOReturnSuccess else {
            throw AppleSMCReaderError.openFailed(result)
        }
        connection = openedConnection

        do {
            let fanCount = try Self.readFanCount(connection)
            let keys = try Self.discoverTemperatureKeys(connection)
            catalog = SystemSensorCatalog(
                cpuTemperatureKeys: keys.cpu,
                gpuTemperatureKeys: keys.gpu,
                fanCount: fanCount
            )
        } catch {
            IOServiceClose(openedConnection)
            throw error
        }
    }

    deinit {
        IOServiceClose(connection)
    }

    func readTemperatures() -> AppleSMCTemperatureSample {
        let cpu = readTemperatureKeys(catalog.cpuTemperatureKeys)
        let gpu = readTemperatureKeys(catalog.gpuTemperatureKeys)
        return AppleSMCTemperatureSample(
            cpu: cpu.values,
            gpu: gpu.values,
            invalidCPUCount: cpu.invalidCount,
            invalidGPUCount: gpu.invalidCount
        )
    }

    func readFans() throws -> [PrivateFanMetrics] {
        guard let fanCount = catalog.fanCount else {
            throw AppleSMCReaderError.fanCountMalformed
        }
        guard fanCount > 0 else { return [] }
        var fans = [PrivateFanMetrics]()
        fans.reserveCapacity(fanCount)
        for index in 0..<fanCount {
            let key = "F\(index)Ac"
            guard let value = try readNumericValue(key), value.isFinite, value >= 0 else {
                throw AppleSMCReaderError.readFailed(key)
            }
            fans.append(PrivateFanMetrics(id: index, name: "Fan \(index + 1)", rpm: value))
        }
        return fans
    }

    private func readTemperatureKeys(
        _ keys: [SystemSensorCatalog.Key]
    ) -> (values: [Double], invalidCount: Int) {
        var values = [Double]()
        var invalidCount = 0
        values.reserveCapacity(keys.count)
        for key in keys {
            guard let value = try? readFloat(key), value.isFinite, (-10...125).contains(value) else {
                invalidCount += 1
                continue
            }
            values.append(value)
        }
        return (values, invalidCount)
    }

    private func readFloat(_ key: SystemSensorCatalog.Key) throws -> Double {
        guard key.size >= 4 else { throw AppleSMCReaderError.readFailed("temperature") }
        var input = SMCKeyData()
        input.key = key.code
        input.keyInfo.dataSize = key.size
        input.command = Self.readKey
        let output = try call(&input)
        let bits = withUnsafeBytes(of: output.bytes) { raw in
            UInt32(raw[0])
                | UInt32(raw[1]) << 8
                | UInt32(raw[2]) << 16
                | UInt32(raw[3]) << 24
        }
        return Double(Float(bitPattern: bits))
    }

    private func readNumericValue(_ name: String) throws -> Double? {
        let code = Self.fourCC(name)
        var infoInput = SMCKeyData()
        infoInput.key = code
        infoInput.command = Self.keyInfo
        let info = try call(&infoInput)

        var readInput = SMCKeyData()
        readInput.key = code
        readInput.keyInfo.dataSize = info.keyInfo.dataSize
        readInput.command = Self.readKey
        let output = try call(&readInput)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(32)) }

        switch Self.string(from: info.keyInfo.dataType) {
        case "ui8 ":
            return Double(bytes[0])
        case "ui16":
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            return Double(
                UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                    | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            )
        case "flt ":
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        default:
            return nil
        }
    }

    private func call(_ input: inout SMCKeyData) throws -> SMCKeyData {
        try Self.call(connection, &input)
    }

    private static func call(
        _ connection: io_connect_t,
        _ input: inout SMCKeyData
    ) throws -> SMCKeyData {
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection,
            selector,
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else {
            throw AppleSMCReaderError.readFailed("smcCall")
        }
        return output
    }

    private static func readFanCount(_ connection: io_connect_t) throws -> Int? {
        let code = fourCC("FNum")
        var infoInput = SMCKeyData()
        infoInput.key = code
        infoInput.command = keyInfo
        let info: SMCKeyData
        do {
            info = try call(connection, &infoInput)
        } catch {
            return nil
        }

        var readInput = SMCKeyData()
        readInput.key = code
        readInput.keyInfo.dataSize = info.keyInfo.dataSize
        readInput.command = readKey
        let output = try call(connection, &readInput)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(4)) }
        switch string(from: info.keyInfo.dataType) {
        case "ui8 ": return Int(bytes[0])
        case "ui16": return Int(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            guard value <= 16 else { throw AppleSMCReaderError.fanCountMalformed }
            return Int(value)
        default: throw AppleSMCReaderError.fanCountMalformed
        }
    }

    private static func discoverTemperatureKeys(
        _ connection: io_connect_t
    ) throws -> (cpu: [SystemSensorCatalog.Key], gpu: [SystemSensorCatalog.Key]) {
        var countInput = SMCKeyData()
        countInput.key = fourCC("#KEY")
        countInput.keyInfo.dataSize = 4
        countInput.command = readKey
        let countOutput = try call(connection, &countInput)
        let count = withUnsafeBytes(of: countOutput.bytes) { raw in
            UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16
                | UInt32(raw[2]) << 8 | UInt32(raw[3])
        }
        guard count > 0, count < 20_000 else {
            throw AppleSMCReaderError.keyCountUnavailable
        }

        var cpu = [SystemSensorCatalog.Key]()
        var gpu = [SystemSensorCatalog.Key]()
        for index in 0..<count {
            var indexInput = SMCKeyData()
            indexInput.command = keyByIndex
            indexInput.data32 = index
            guard let keyOutput = try? call(connection, &indexInput), keyOutput.key != 0 else {
                continue
            }

            var infoInput = SMCKeyData()
            infoInput.key = keyOutput.key
            infoInput.command = keyInfo
            guard let info = try? call(connection, &infoInput),
                  info.keyInfo.dataType == floatType else {
                continue
            }

            let name = string(from: keyOutput.key)
            let key = SystemSensorCatalog.Key(
                code: keyOutput.key,
                size: info.keyInfo.dataSize
            )
            switch SystemSensorCatalog.temperatureDomain(for: name) {
            case "cpu": cpu.append(key)
            case "gpu": gpu.append(key)
            default: break
            }
        }
        return (cpu, gpu)
    }

    private static func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func string(from value: UInt32) -> String {
        String(bytes: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ], encoding: .ascii) ?? ""
    }
}
