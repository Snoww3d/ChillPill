import Foundation
import IOKit

/// Userspace client for the `AppleSMC` service.
///
/// The System Management Controller exposes named 4-byte keys (e.g. `F0Ac`,
/// `TC0P`) that describe fan speeds, temperatures, voltages, and similar
/// telemetry. We talk to the kernel userclient using method selector
/// `kSMCHandleYPCEvent = 2`, passing an 80-byte `SMCParamStruct` in both
/// directions. The sub-selector in byte 42 picks the operation:
///   - `kSMCGetKeyInfo  = 9` — returns dataSize + dataType for a key
///   - `kSMCReadKey     = 5` — returns up to 32 bytes of value data
///   - `kSMCWriteKey    = 6` — writes up to 32 bytes (root-only on AS)
///
/// SMC byte-order is largely big-endian, with one Apple Silicon twist:
/// `flt ` values (used for fan RPM on M-series) are little-endian. Signed
/// fixed-point (`sp78`) and unsigned fixed-point (`fp*`, `ui*`) keys remain
/// big-endian.
final class SMC {

    // MARK: - Public API

    static let shared = SMC()

    enum SMCError: Error {
        case serviceNotFound
        case openFailed(kern_return_t)
        case callFailed(kern_return_t)
        case smcResult(UInt8)
    }

    struct KeyInfo {
        let dataSize: UInt32
        let dataType: String   // FourCC like "sp78", "flt ", "ui8 "
    }

    struct Value {
        let key: String
        let info: KeyInfo
        let bytes: [UInt8]
    }

    /// Returns nil if the key is absent or SMC reports an error.
    func read(_ key: String) -> Value? {
        guard ensureOpen() else { return nil }
        guard let info = getKeyInfo(key) else { return nil }
        guard let bytes = readBytes(key, size: info.dataSize) else { return nil }
        return Value(key: key, info: info, bytes: bytes)
    }

    /// Read & decode a key as Double. Returns nil for unknown / unsupported types.
    func readDouble(_ key: String) -> Double? {
        read(key).flatMap { Self.decode($0) }
    }

    // MARK: - Decoding

    static func decode(_ v: Value) -> Double? {
        let b = v.bytes
        switch v.info.dataType {
        case "sp78":
            guard b.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
            return Double(raw) / 256.0
        case "flt ":
            guard b.count >= 4 else { return nil }
            // Apple Silicon SMC emits `flt ` as little-endian IEEE754.
            let u = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: u))
        case "ui8 ":
            return b.first.map(Double.init)
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "fpe2":
            guard b.count >= 2 else { return nil }
            let raw = UInt16(b[0]) << 8 | UInt16(b[1])
            return Double(raw) / 4.0
        case "fp1f":
            guard b.count >= 2 else { return nil }
            let raw = UInt16(b[0]) << 8 | UInt16(b[1])
            return Double(raw) / 32768.0
        default:
            return nil
        }
    }

    // MARK: - Lifecycle

    private var connection: io_connect_t = 0
    private var isOpen = false

    private init() {}

    deinit {
        if isOpen {
            IOServiceClose(connection)
        }
    }

    private func ensureOpen() -> Bool {
        if isOpen { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { return false }
        isOpen = true
        return true
    }

    // MARK: - Wire protocol

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCGetKeyInfo: UInt8 = 9

    /// SMCParamStruct is 80 bytes. Relevant offsets:
    ///   0   UInt32 key           (4-char code, natural byte order on LE host
    ///                             matches SMC's expected byte sequence)
    ///   28  UInt32 keyInfo.dataSize
    ///   32  UInt32 keyInfo.dataType (FourCC)
    ///   40  UInt8  result         (0 = success, 0x84 = key not found, …)
    ///   41  UInt8  status
    ///   42  UInt8  data8          (sub-selector)
    ///   44  UInt32 data32
    ///   48  UInt8  bytes[32]
    private static let paramStructSize = 80

    private func buildInput(key: String, selector: UInt8, dataSize: UInt32 = 0, payload: [UInt8] = []) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: Self.paramStructSize)
        // The kernel stores `UInt32 key` in native byte order. On little-endian
        // machines the FourCC 'F0Ac' = 0x46304163 ends up in memory as
        // 63 41 30 46. Compute the natural-order UInt32 and write it little-
        // endian so the kernel reads the expected value on the other side.
        writeLE32(&buf, at: 0, fourCC(key))
        writeLE32(&buf, at: 28, dataSize)
        buf[42] = selector
        for (i, byte) in payload.prefix(32).enumerated() {
            buf[48 + i] = byte
        }
        return buf
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Self.paramStructSize)
        var outSize = Self.paramStructSize
        let kr = input.withUnsafeBufferPointer { inPtr -> kern_return_t in
            output.withUnsafeMutableBufferPointer { outPtr -> kern_return_t in
                IOConnectCallStructMethod(
                    connection,
                    Self.kSMCHandleYPCEvent,
                    inPtr.baseAddress, inPtr.count,
                    outPtr.baseAddress, &outSize
                )
            }
        }
        guard kr == kIOReturnSuccess else { return nil }
        guard output[40] == 0 else { return nil }
        return output
    }

    private func getKeyInfo(_ key: String) -> KeyInfo? {
        let input = buildInput(key: key, selector: Self.kSMCGetKeyInfo)
        guard let output = call(input) else { return nil }
        let dataSize = readLE32(output, at: 28)
        // dataType is the same story as the key: native UInt32 on LE memory,
        // so the ascii chars appear reversed in the byte stream.
        let typeU32 = readLE32(output, at: 32)
        let typeBytes: [UInt8] = [
            UInt8((typeU32 >> 24) & 0xff),
            UInt8((typeU32 >> 16) & 0xff),
            UInt8((typeU32 >>  8) & 0xff),
            UInt8( typeU32        & 0xff),
        ]
        let dataType = String(bytes: typeBytes, encoding: .ascii) ?? "????"
        return KeyInfo(dataSize: dataSize, dataType: dataType)
    }

    private func readBytes(_ key: String, size: UInt32) -> [UInt8]? {
        let input = buildInput(key: key, selector: Self.kSMCReadKey, dataSize: size)
        guard let output = call(input) else { return nil }
        let count = min(Int(size), 32)
        return Array(output[48..<(48 + count)])
    }

    // MARK: - Helpers

    private func fourCC(_ key: String) -> UInt32 {
        var v: UInt32 = 0
        for c in key.utf8.prefix(4) {
            v = (v << 8) | UInt32(c)
        }
        return v
    }

    private func writeLE32(_ buf: inout [UInt8], at offset: Int, _ value: UInt32) {
        buf[offset]     = UInt8(value        & 0xff)
        buf[offset + 1] = UInt8((value >> 8)  & 0xff)
        buf[offset + 2] = UInt8((value >> 16) & 0xff)
        buf[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func readLE32(_ buf: [UInt8], at offset: Int) -> UInt32 {
        UInt32(buf[offset])
            | UInt32(buf[offset + 1]) << 8
            | UInt32(buf[offset + 2]) << 16
            | UInt32(buf[offset + 3]) << 24
    }
}
