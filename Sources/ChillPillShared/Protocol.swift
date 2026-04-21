import Foundation

/// Mach service name for the helper's XPC listener. Must match the `Label`
/// and `MachServices` entry in `dev.chillpill.helper.plist`.
public let ChillPillHelperMachServiceName = "dev.chillpill.helper"

/// High-level category a thermal sensor belongs to, used to group the menu
/// dropdown. Order here defines the display order — the menu reads top-down
/// from "hottest under CPU load" to "slowest-moving".
public enum SensorGroup: String, Codable, CaseIterable, Sendable {
    case pcore   = "P-Cores"
    case ecore   = "E-Cores"
    case soc     = "SoC"
    /// Fallback for Intel / non-M-series CPU sensors and anything CPU-adjacent
    /// that doesn't fit the P-core / E-core / SoC split (e.g. generic SMC
    /// `TC*` keys). On a typical M-series Mac this group will be empty.
    case cpu     = "CPU"
    case gpu     = "GPU"
    case memory  = "Memory"
    case storage = "Storage"
    case battery = "Battery"
    case ambient = "Ambient"
    case other   = "Other"
}

public struct FanDTO: Codable, Sendable {
    public let index: Int
    public let actualRPM: Double
    public let minRPM: Double?
    public let maxRPM: Double?
    public let targetRPM: Double?
    /// 0 = auto, 1 = forced. nil if the key isn't exposed on this hardware.
    public let mode: Int?

    public init(index: Int, actualRPM: Double, minRPM: Double?, maxRPM: Double?,
                targetRPM: Double?, mode: Int?) {
        self.index = index
        self.actualRPM = actualRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.mode = mode
    }
}

public struct TemperatureDTO: Codable, Sendable {
    /// Underlying identifier — IOHID Product string or SMC FourCC.
    public let rawName: String
    public let displayName: String
    public let celsius: Double
    public let group: SensorGroup

    public init(rawName: String, displayName: String, celsius: Double, group: SensorGroup) {
        self.rawName = rawName
        self.displayName = displayName
        self.celsius = celsius
        self.group = group
    }
}

/// XPC protocol the helper exposes to the UI app. Defined as `@objc` because
/// `NSXPCConnection` requires Objective-C protocol semantics.
///
/// Array-valued returns are JSON-encoded as `Data` blobs to sidestep
/// `NSSecureCoding` class whitelisting for generic Swift `Codable` types —
/// overhead is negligible (~microseconds) for the sizes we deal with.
///
/// Writes take a `reply` with an optional `NSError` — nil on success, a
/// descriptive error on any failure (validation rejected, SMC write
/// refused, helper not talking to SMC, etc.).
@objc public protocol ChillPillHelperProtocol {
    /// Health check. Reply is the helper's build identifier / version.
    func ping(reply: @escaping (String) -> Void)

    /// JSON-encoded `[FanDTO]`.
    func fans(reply: @escaping (Data?, NSError?) -> Void)

    /// JSON-encoded `[TemperatureDTO]` — HID + SMC merged and deduplicated
    /// by the helper.
    func temperatures(reply: @escaping (Data?, NSError?) -> Void)

    func setFanAuto(index: Int, reply: @escaping (NSError?) -> Void)
    func setFanTarget(index: Int, rpm: Double, reply: @escaping (NSError?) -> Void)
    func setAllFansAuto(reply: @escaping (NSError?) -> Void)
    func setAllFansTarget(pct: Double, reply: @escaping (NSError?) -> Void)

    /// Restore every fan to auto and shut down the helper's SMC client.
    /// Called by the UI on clean quit as a belt-and-braces safety net;
    /// the helper's own signal handling also calls this.
    func prepareForShutdown(reply: @escaping (NSError?) -> Void)
}

/// Shared helper-error domain for the NSError objects returned by the XPC
/// protocol. Keeps the error construction consistent across helper sites
/// and lets the UI match on `code` rather than string-parsing messages.
public enum ChillPillHelperErrorCode: Int {
    case invalidIndex        = 1
    case invalidRPM          = 2
    case rangeUnknown        = 3
    case smcWriteFailed      = 4
    case smcReadFailed       = 5
    case keyNotAllowed       = 6
    case notAuthorized       = 7
    case internalFailure     = 99
}

public let ChillPillHelperErrorDomain = "dev.chillpill.helper"

public func chillPillHelperError(_ code: ChillPillHelperErrorCode, _ message: String) -> NSError {
    NSError(
        domain: ChillPillHelperErrorDomain,
        code: code.rawValue,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
