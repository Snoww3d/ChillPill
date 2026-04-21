import Foundation
import CChillPillIOKit

struct ThermalReading {
    /// Underlying sensor identifier: either an IOHID `Product` string (like
    /// `"pACC MTR Temp Sensor0"`) or an SMC FourCC (like `"Ts0P"`). Kept for
    /// classification and debugging — the UI uses `displayName`.
    let rawName: String
    /// Human-friendly label shown in the menu. See `Sensors.friendlyName`
    /// and `Sensors.smcFriendlyName`.
    let displayName: String
    let celsius: Double
    let source: Source

    enum Source { case hid, smc }
}

/// High-level category a thermal sensor belongs to, used to group the menu
/// dropdown. Order here is the display order in the menu.
enum SensorGroup: String, CaseIterable {
    case cpu     = "CPU"
    case gpu     = "GPU"
    case memory  = "Memory"
    case storage = "Storage"
    case battery = "Battery"
    case ambient = "Ambient"
    case other   = "Other"
}

enum Sensors {
    /// HID usage page / usage identifying Apple thermal sensors.
    /// 0xFF00 = kHIDPage_AppleVendor, 0x0005 = temperature sensor.
    private static let usagePage: Int32 = 0xFF00
    private static let usage: Int32 = 0x0005

    /// Event type 15 = kIOHIDEventTypeTemperature; field = type << 16.
    private static let eventTypeTemperature: Int64 = 15
    private static let fieldTemperatureLevel: Int32 = 15 << 16

    static func readThermal() -> [ThermalReading] {
        var readings = readHIDTemperatures()
        let seenDisplayNames = Set(readings.map { $0.displayName })
        for smc in readSMCTemperatures() {
            // HID sources tend to be more descriptive; if we have the same
            // display label from HID, skip the SMC duplicate.
            if seenDisplayNames.contains(smc.displayName) { continue }
            readings.append(smc)
        }
        return readings.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - HID (per-die / per-block sensors)

    private static func readHIDTemperatures() -> [ThermalReading] {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else {
            return []
        }
        let matching: [String: Any] = [
            "PrimaryUsagePage": usagePage,
            "PrimaryUsage": usage
        ]
        _ = IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)

        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [CFTypeRef] else {
            return []
        }

        var readings: [ThermalReading] = []
        for service in services {
            let raw = (IOHIDServiceClientCopyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String) ?? "Unknown"
            guard let display = friendlyName(raw) else { continue }
            guard let event = IOHIDServiceClientCopyEvent(
                service,
                eventTypeTemperature,
                0,
                0
            )?.takeRetainedValue() else { continue }
            let value = IOHIDEventGetFloatValue(event, fieldTemperatureLevel)
            if value.isFinite && value > -50 && value < 150 {
                readings.append(ThermalReading(
                    rawName: raw, displayName: display, celsius: value, source: .hid))
            }
        }
        return readings
    }

    // MARK: - SMC (board-level / location-based sensors)
    //
    // On Apple Silicon the SMC exposes a set of FourCC temperature keys
    // distinct from the per-die IOHID surface. These are where the
    // location-based thermistors live (palm rest, airflow intakes, wireless
    // module, SSD area, etc.). We enumerate the SMC key table once at
    // startup, filter to temperature-typed keys starting with 'T' whose
    // initial read produces a plausible value, and cache the list so each
    // subsequent refresh only pays for the value reads.

    /// `DiscoveredKey` wraps enough metadata to re-read a key without a
    /// second `getKeyInfo` round-trip on every refresh.
    private static var smcCache: [SMC.DiscoveredKey]?

    private static let temperatureDataTypes: Set<String> = [
        "sp78", "sp87", "sp96", "sp69", "flt ", "fpe2", "fp1f"
    ]

    private static func readSMCTemperatures() -> [ThermalReading] {
        let candidates = cachedSMCTemperatureKeys()
        var readings: [ThermalReading] = []
        for k in candidates {
            guard let display = smcFriendlyName(k.key) else { continue }
            guard let value = SMC.shared.readWithInfo(k.key, info: k.info)
                .flatMap({ SMC.decode($0) }) else { continue }
            guard value.isFinite, value > -50, value < 150 else { continue }
            readings.append(ThermalReading(
                rawName: k.key, displayName: display, celsius: value, source: .smc))
        }
        return readings
    }

    private static func cachedSMCTemperatureKeys() -> [SMC.DiscoveredKey] {
        if let cached = smcCache { return cached }
        let all = SMC.shared.discoverAllKeys()
        let filtered = all.filter { k in
            guard k.key.hasPrefix("T"), k.key.count == 4 else { return false }
            guard temperatureDataTypes.contains(k.info.dataType) else { return false }
            // Probe once: reject keys that don't return a plausible value
            // even on a cold boot. Some T-prefixed keys (e.g. TSfa, TSfw)
            // report status flags, not temperatures.
            guard let v = SMC.shared.readWithInfo(k.key, info: k.info)
                .flatMap({ SMC.decode($0) }) else { return false }
            return v.isFinite && v > -50 && v < 150
        }
        smcCache = filtered
        return filtered
    }

    // MARK: - Best-effort CPU headline

    /// Headline CPU temperature — the hottest P-core (pACC). Prior logic
    /// folded efficiency cores, SoC fabric, and PMGR sensors into the pool,
    /// which diluted the displayed number during a CPU burst. Falls back to
    /// anything in the .cpu group if no pACC sensors are present.
    static func hottestCPU(_ readings: [ThermalReading]) -> ThermalReading? {
        let pCores = readings.filter { $0.rawName.hasPrefix("pACC ") }
        if let hottest = pCores.max(by: { $0.celsius < $1.celsius }) {
            return hottest
        }
        let cpuish = readings.filter { group(for: $0) == .cpu }
        return (cpuish.isEmpty ? readings : cpuish).max { $0.celsius < $1.celsius }
    }

    // MARK: - Classification

    /// Classify a sensor into a display group. Handles both HID Product
    /// strings and 4-char SMC FourCC keys.
    static func group(for reading: ThermalReading) -> SensorGroup {
        // SMC FourCC: second char identifies the domain.
        if reading.source == .smc, reading.rawName.count == 4 {
            return smcGroup(fourCC: reading.rawName) ?? .other
        }

        let n = reading.rawName.lowercased()
        // Storage first so "NAND CPU Die" routes to storage, not CPU.
        if n.contains("ssd") || n.contains("nand")
            || n.contains("flash") || n.contains("storage") {
            return .storage
        }
        if n.contains("battery") || n.contains("charger")
            || n.contains("gas gauge") || n.contains("gas guage") {
            return .battery
        }
        if n.contains("ambient") || n.contains("airflow") || n.contains("skin")
            || n.contains("palm") {
            return .ambient
        }
        if n.contains("gpu") {
            return .gpu
        }
        if n.contains("cpu") || n.contains("pecpu") || n.contains("ecpu")
            || n.contains("pcpu") || n.contains("pmp") || n.contains("soc")
            || n.contains("efuse")
            || n.contains("pacc") || n.contains("eacc") {
            return .cpu
        }
        if n.contains("dram") || n.contains("memory") || n.contains("mem ") {
            return .memory
        }
        return .other
    }

    /// SMC FourCC domain letter → group. See Apple's SMC key conventions
    /// plus VirtualSMC's `SMCSensorKeys.txt` for the full lexicon. We only
    /// codify the `T` temperature family here.
    private static func smcGroup(fourCC key: String) -> SensorGroup? {
        guard key.count == 4, key.hasPrefix("T") else { return nil }
        let chars = Array(key)
        switch chars[1] {
        case "B", "b":        return .battery
        case "C", "p", "P":   return .cpu      // TCxx, Tpxx (P-core), TPCD
        case "e":             return .cpu      // Texx (E-core)
        case "G", "g":        return .gpu
        case "H", "h":        return .storage  // TH*, Th*  (SSD / bay)
        case "M", "m":        return .memory
        case "N":             return .cpu      // TN*D / TN*P → SoC north / MCP
        case "A", "a":        return .ambient  // TaLP, TaRF, TAxx (airflow)
        case "s":             return .ambient  // Ts0P palm rest, Tskn skin
        case "W", "w":        return .other    // wireless / Wi-Fi / BT
        case "f":             return .other    // Tf*: heatsink fins
        case "S":             return .other    // TS*: system status / misc
        default:              return .other
        }
    }

    // MARK: - Grouping helper

    /// Returns readings grouped by `SensorGroup`, preserving the order
    /// defined in `SensorGroup.allCases`. Empty groups are omitted.
    static func grouped(_ readings: [ThermalReading]) -> [(SensorGroup, [ThermalReading])] {
        let byGroup = Dictionary(grouping: readings, by: { group(for: $0) })
        return SensorGroup.allCases.compactMap { g in
            guard let list = byGroup[g], !list.isEmpty else { return nil }
            return (g, list.sorted { $0.displayName < $1.displayName })
        }
    }

    // MARK: - Friendly name: HID side

    /// Returns a user-facing label for an IOHID `Product` string, or nil if
    /// the sensor should be hidden from the UI entirely.
    static func friendlyName(_ raw: String) -> String? {
        if raw.hasPrefix("Avg:") || raw.hasPrefix("Max:") { return nil }
        if raw == "PMU tcal" { return nil }

        switch raw {
        case "gas gauge battery": return "Battery"
        case "PMU tdie":  return "PMIC Die"
        case "PMU tjunc": return "PMIC Die"
        case "Unknown":   return "Unknown"
        default: break
        }

        if let n = tailDigit(raw, prefix: "pACC MTR Temp Sensor")  { return "P-Core \(n)" }
        if let n = tailDigit(raw, prefix: "eACC MTR Temp Sensor")  { return "E-Core \(n)" }
        if let n = tailDigit(raw, prefix: "GPU MTR Temp Sensor")   { return "GPU \(n)" }
        if let n = tailDigit(raw, prefix: "SOC MTR Temp Sensor")   { return "SoC Fabric \(n)" }
        if let n = tailDigit(raw, prefix: "ANE MTR Temp Sensor")   { return "Neural Engine \(n)" }
        if let n = tailDigit(raw, prefix: "ISP MTR Temp Sensor")   { return "ISP \(n)" }
        if let n = tailDigit(raw, prefix: "PMGR SOC Die Temp Sensor") { return "SoC Die \(n)" }
        if let n = tailDigit(raw, prefix: "TCC Temp Sensor")       { return "Thermal Zone \(n)" }

        if raw.hasPrefix("NAND CH"), raw.hasSuffix(" temp") {
            let inner = raw.dropFirst("NAND CH".count).dropLast(" temp".count)
            if !inner.isEmpty { return "SSD Ch \(inner)" }
        }

        if let n = tailDigit(raw, prefix: "PMU tdie") { return "PMIC Die \(n)" }
        if let n = tailDigit(raw, prefix: "PMU tdev") { return "PMIC Sensor \(n)" }
        if raw.hasPrefix("PMU ") {
            return "PMIC Sensor"
        }

        var cleaned = raw
        for noise in [" MTR Temp Sensor", " Temp Sensor", " temp"] {
            cleaned = cleaned.replacingOccurrences(of: noise, with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? raw : cleaned
    }

    // MARK: - Friendly name: SMC side
    //
    // SMC 4-char keys are largely standardized across Intel and Apple Silicon
    // Macs, though the set of keys that actually exists varies by model.
    // We map the common "location" keys — palm rest, airflow, wireless, SSD
    // area — to descriptive labels, and hide keys that duplicate IOHID
    // sensors (e.g. per-core Tp/Te, battery TB*T are already covered by HID).
    // Keys we don't have a label for fall through to a raw-code display
    // ("SMC Ts0P") so the user can still see "something exists" and we can
    // iterate on the table.
    //
    // References: Apple SMC conventions, VirtualSMC `SMCSensorKeys.txt`,
    // asahilinux.org/docs/hw/soc/smc, and community dumps.

    static func smcFriendlyName(_ key: String) -> String? {
        // Explicit hides: duplicated by HID, or not a real temperature.
        switch key {
        case "TB0T", "TB1T", "TB2T", "TB3T":           return nil  // battery (HID "gas gauge battery")
        case "TH0x":                                   return nil  // often status, not temperature
        default: break
        }

        // Skip per-core keys that overlap with IOHID pACC/eACC labels.
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tg") {
            return nil
        }

        // Exact-match table of well-known location keys.
        switch key {
        case "TC0P": return "CPU Proximity"
        case "TC0D", "TC0E", "TC0F": return "CPU Package"
        case "TCPA", "TCPB":         return "CPU Area"
        case "TG0P": return "GPU Proximity"
        case "TG0D": return "GPU Package"
        case "TM0P", "TM1P": return "Memory Proximity"
        case "TM0D", "TM1D": return "Memory Die"
        case "TN0D": return "MCP Die"
        case "TN0P": return "MCP"
        case "TH0P": return "SSD Proximity"
        case "TH0a", "TH1a", "TH2a": return "SSD Area"
        case "TH1F", "TH2F": return "SSD"
        case "Ts0P": return "Palm Rest"
        case "Ts1P": return "Palm Rest Right"
        case "Ts0S": return "Palm Rest Below"
        case "Ts1S": return "Palm Rest Below Right"
        case "Tskn": return "Skin"
        case "TSMY": return "Keyboard"
        case "Ts0p": return "Palm Rest (lower)"
        case "TaLP": return "Airflow Left"
        case "TaRF", "TaRP": return "Airflow Right"
        case "TaCP": return "Airflow Center"
        case "TA0P", "TA1P", "TA2P": return "Airflow"
        case "TW0P": return "Wireless"
        case "TW1P": return "Wireless (aux)"
        case "TCHP": return "Charger"
        case "TPCD": return "PCH Die"
        case "TCGC", "TCSA": return "CPU SoC"
        case "TCXC", "TCXR": return "CPU Cluster"
        case "Tp09", "Tp0D", "Tp0T": return nil // covered by HID pACC
        case "Tskn_": return "Skin"
        case "TBXT": return nil
        case "Tfin", "Tf0F": return "Heatsink"
        default: break
        }

        // Unknown key: expose so the user can see it exists. We prefix with
        // "SMC" so it's clearly from a different source than the HID names.
        return "SMC \(key)"
    }

    /// If `raw` starts with `prefix` and the remainder is a non-empty digit
    /// string, returns that digit string; otherwise nil.
    private static func tailDigit(_ raw: String, prefix: String) -> String? {
        guard raw.hasPrefix(prefix) else { return nil }
        let tail = raw.dropFirst(prefix.count)
        guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(tail)
    }
}
