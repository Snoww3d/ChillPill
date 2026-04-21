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

// MARK: - Target-temperature controller (issue #10)

/// Which temperature reading the controller tracks. v1 is group-based — a
/// future version can add `.rawName(String)` for specific-sensor selection.
public enum SensorSelector: Codable, Sendable, Equatable {
    /// Hottest sensor in the group (`max` of `.celsius`). Default choice for
    /// thermal control — the system is limited by its hottest die, not its
    /// average die.
    case groupMax(SensorGroup)
    /// Arithmetic mean across the group. Quieter signal, slower response.
    case groupAvg(SensorGroup)
}

/// Predefined PI gain triple. Presets keep the v1 UI simple — users pick one
/// of three labels instead of tweaking raw Kp/Ki fields.
public enum ControlPreset: String, Codable, Sendable, CaseIterable {
    case conservative
    case balanced
    case aggressive
}

/// Live state of the fan controller, returned by `getControlState`. The
/// "current" fields are sampled from the most recent tick; they are nil
/// before the first tick completes or when the selected sensor group has
/// no readings.
public struct ControlStateDTO: Codable, Sendable {
    public let enabled: Bool
    public let resumeOnLaunch: Bool
    public let sensor: SensorSelector
    public let setpointCelsius: Double
    public let preset: ControlPreset
    public let currentReadingCelsius: Double?
    public let currentErrorCelsius: Double?
    public let lastOutputPercent: Double?
    /// When non-nil, the controller self-disabled because of this condition
    /// (sensor group went empty, fan range unknown, etc.). The UI surfaces
    /// this so the user knows why the controller is off.
    public let fallbackReason: String?

    public init(enabled: Bool,
                resumeOnLaunch: Bool,
                sensor: SensorSelector,
                setpointCelsius: Double,
                preset: ControlPreset,
                currentReadingCelsius: Double?,
                currentErrorCelsius: Double?,
                lastOutputPercent: Double?,
                fallbackReason: String?) {
        self.enabled = enabled
        self.resumeOnLaunch = resumeOnLaunch
        self.sensor = sensor
        self.setpointCelsius = setpointCelsius
        self.preset = preset
        self.currentReadingCelsius = currentReadingCelsius
        self.currentErrorCelsius = currentErrorCelsius
        self.lastOutputPercent = lastOutputPercent
        self.fallbackReason = fallbackReason
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

    // MARK: - Target-temperature controller (issue #10)

    /// JSON-encoded `ControlStateDTO`. Always non-nil when no error.
    func getControlState(reply: @escaping (Data?, NSError?) -> Void)

    /// Turn the controller on or off. Disabling immediately returns all fans
    /// to auto and clears any fallback reason. Enabling is rejected if the
    /// selected sensor group currently has no readings.
    func setControlEnabled(_ enabled: Bool, reply: @escaping (NSError?) -> Void)

    /// Setpoint in °C. Rejected if non-finite or outside `[20, 110]`.
    func setControlSetpoint(_ celsius: Double, reply: @escaping (NSError?) -> Void)

    /// JSON-encoded `SensorSelector`. Rejected if decode fails.
    func setControlSensor(selectorData: Data, reply: @escaping (NSError?) -> Void)

    /// Preset name matching one of `ControlPreset.rawValue`.
    func setControlPreset(_ presetName: String, reply: @escaping (NSError?) -> Void)

    /// If true, the controller will re-enable itself with the persisted
    /// config on the next helper launch. Default false.
    func setControlResumeOnLaunch(_ enabled: Bool, reply: @escaping (NSError?) -> Void)
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
    // Controller errors (issue #10)
    case invalidSetpoint     = 10
    case invalidSensor       = 11
    case invalidPreset       = 12
    case sensorUnavailable   = 13
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
