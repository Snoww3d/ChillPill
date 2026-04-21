import Foundation
import IOKit
import os.log

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
/// Endianness:
///   - The `UInt32 key` field and `keyInfo.dataType` (also UInt32) are written
///     and read as *native* UInt32s by the kernel. On a little-endian host
///     that means the 4 ascii chars of a FourCC appear *reversed* in the
///     80-byte buffer — which is why we write with `writeLE32(fourCC)` rather
///     than copying the utf8 bytes in order, and why decoding `dataType`
///     reads `readLE32` then extracts bytes big-end first.
///   - Payload bytes in `buf[48..]` are key-type specific. `flt ` is little-
///     endian IEEE754 on Apple Silicon; `sp78`, `fp*`, and `ui*` are big-
///     endian. The `decode(_:)` and `encodeFLT(_:)` helpers encapsulate this.
final class SMC {

    // MARK: - Public API

    static let shared = SMC()

    /// Max bytes any SMC key can carry — matches the `bytes[32]` field in the
    /// 80-byte SMCParamStruct. Reads/writes exceeding this are rejected.
    static let maxPayloadSize = 32

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
        guard info.dataSize <= UInt32(Self.maxPayloadSize) else {
            os_log(
                "SMC: refusing read of %{public}@ — kernel claims dataSize=%u > %d",
                log: Self.log, type: .error, key, info.dataSize, Self.maxPayloadSize
            )
            return nil
        }
        guard let bytes = readBytes(key, size: info.dataSize) else { return nil }
        return Value(key: key, info: info, bytes: bytes)
    }

    /// Read & decode a key as Double. Returns nil for unknown / unsupported types.
    func readDouble(_ key: String) -> Double? {
        read(key).flatMap { Self.decode($0) }
    }

    /// Write raw bytes to a key. Byte count must match the key's advertised
    /// `dataSize`. Returns false on any failure (missing key, wrong size,
    /// userclient rejected the call — typically because the process is not
    /// root).
    @discardableResult
    func write(_ key: String, bytes: [UInt8]) -> Bool {
        guard ensureOpen() else { return false }
        guard bytes.count <= Self.maxPayloadSize else { return false }
        guard let info = getKeyInfo(key) else { return false }
        guard info.dataSize <= UInt32(Self.maxPayloadSize) else { return false }
        guard bytes.count == Int(info.dataSize) else { return false }
        guard let input = buildInput(
            key: key,
            selector: Self.kSMCWriteKey,
            dataSize: info.dataSize,
            payload: bytes
        ) else { return false }
        return call(input) != nil
    }

    /// Encode a 32-bit float for an SMC `flt ` key. On Apple Silicon the
    /// SMC stores these little-endian (same as the host).
    static func encodeFLT(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return [
            UInt8( bits        & 0xff),
            UInt8((bits >> 8)  & 0xff),
            UInt8((bits >> 16) & 0xff),
            UInt8((bits >> 24) & 0xff),
        ]
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
            os_log(
                "SMC: unhandled dataType %{public}@ for key %{public}@",
                log: Self.log, type: .debug, v.info.dataType, v.key
            )
            return nil
        }
    }

    // MARK: - Lifecycle

    private static let log = OSLog(subsystem: "dev.chillpill", category: "SMC")

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
    private static let kSMCWriteKey: UInt8 = 6
    private static let kSMCGetKeyInfo: UInt8 = 9

    /// SMCParamStruct is 80 bytes. Relevant offsets:
    ///   0   UInt32 key           (native order; on LE the FourCC appears reversed)
    ///   28  UInt32 keyInfo.dataSize
    ///   32  UInt32 keyInfo.dataType (FourCC, also native order)
    ///   40  UInt8  result         (0 = success, 0x84 = key not found, …)
    ///   41  UInt8  status
    ///   42  UInt8  data8          (sub-selector)
    ///   44  UInt32 data32
    ///   48  UInt8  bytes[32]
    private static let paramStructSize = 80

    private func buildInput(key: String, selector: UInt8, dataSize: UInt32 = 0, payload: [UInt8] = []) -> [UInt8]? {
        guard payload.count <= Self.maxPayloadSize else { return nil }
        guard let fourcc = fourCC(key) else { return nil }
        var buf = [UInt8](repeating: 0, count: Self.paramStructSize)
        writeLE32(&buf, at: 0, fourcc)
        writeLE32(&buf, at: 28, dataSize)
        buf[42] = selector
        if !payload.isEmpty {
            buf.replaceSubrange(48..<(48 + payload.count), with: payload)
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
        // A truncated response would leave `output[40]` as the zero we
        // initialized — which would be misread as SMC success. Require the
        // full param struct came back.
        guard outSize == Self.paramStructSize else { return nil }
        guard output[40] == 0 else { return nil }
        return output
    }

    private func getKeyInfo(_ key: String) -> KeyInfo? {
        guard let input = buildInput(key: key, selector: Self.kSMCGetKeyInfo) else { return nil }
        guard let output = call(input) else { return nil }
        let dataSize = readLE32(output, at: 28)
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
        guard size <= UInt32(Self.maxPayloadSize) else { return nil }
        guard let input = buildInput(key: key, selector: Self.kSMCReadKey, dataSize: size) else {
            return nil
        }
        guard let output = call(input) else { return nil }
        let count = Int(size)
        return Array(output[48..<(48 + count)])
    }

    // MARK: - Helpers

    /// FourCC packing. Requires exactly 4 ASCII (0x20–0x7e) characters. nil on
    /// anything else so callers don't silently send garbage keys.
    private func fourCC(_ key: String) -> UInt32? {
        let bytes = Array(key.utf8)
        guard bytes.count == 4 else { return nil }
        var v: UInt32 = 0
        for c in bytes {
            guard c >= 0x20 && c <= 0x7e else { return nil }
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
