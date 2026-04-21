import Foundation
import CChillPillIOKit

struct ThermalReading {
    /// The original `Product` string returned by `IOHIDServiceClient` — kept
    /// for classification (heuristics read better on raw strings) and for
    /// debugging.
    let rawName: String
    /// Human-friendly label shown in the menu. See `Sensors.friendlyName`.
    let displayName: String
    let celsius: Double
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
            guard let display = friendlyName(raw) else { continue }  // hidden sensor
            guard let event = IOHIDServiceClientCopyEvent(
                service,
                eventTypeTemperature,
                0,
                0
            )?.takeRetainedValue() else { continue }
            let value = IOHIDEventGetFloatValue(event, fieldTemperatureLevel)
            if value.isFinite && value > -50 && value < 150 {
                readings.append(ThermalReading(rawName: raw, displayName: display, celsius: value))
            }
        }
        return readings.sorted { $0.displayName < $1.displayName }
    }

    /// Headline CPU temperature — the hottest P-core (pACC). Prior logic
    /// folded efficiency cores, SoC fabric, and PMGR sensors into the pool,
    /// which diluted the displayed number during a CPU burst. Fall back to
    /// anything in the .cpu group if no pACC sensors are present.
    static func hottestCPU(_ readings: [ThermalReading]) -> ThermalReading? {
        let pCores = readings.filter { $0.rawName.hasPrefix("pACC ") }
        if let hottest = pCores.max(by: { $0.celsius < $1.celsius }) {
            return hottest
        }
        let cpuish = readings.filter { group(for: $0) == .cpu }
        return (cpuish.isEmpty ? readings : cpuish).max { $0.celsius < $1.celsius }
    }

    /// Heuristically classify a thermal sensor by its *raw* name. Keywords are
    /// lower-cased and checked in priority order so, e.g., an "SSD CPU
    /// controller" ends up in .storage rather than .cpu.
    static func group(for reading: ThermalReading) -> SensorGroup {
        let n = reading.rawName.lowercased()
        // Storage first so names like "NAND CPU Die" route to storage.
        if n.contains("ssd") || n.contains("nand")
            || n.contains("flash") || n.contains("storage") {
            return .storage
        }
        if n.contains("battery") || n.contains("charger")
            || n.contains("gas gauge") || n.contains("gas guage") /* typo seen on some boards */ {
            return .battery
        }
        if n.contains("ambient") {
            return .ambient
        }
        if n.contains("gpu") {
            return .gpu
        }
        if n.contains("cpu") || n.contains("pecpu") || n.contains("ecpu")
            || n.contains("pcpu") || n.contains("pmp") || n.contains("soc")
            || n.contains("efuse")
            // M-series cluster sensors are named "pACC"/"eACC".
            || n.contains("pacc") || n.contains("eacc") {
            return .cpu
        }
        if n.contains("dram") || n.contains("memory") || n.contains("mem ") {
            return .memory
        }
        return .other
    }

    /// Returns readings grouped by `SensorGroup`, preserving the order
    /// defined in `SensorGroup.allCases`. Empty groups are omitted.
    static func grouped(_ readings: [ThermalReading]) -> [(SensorGroup, [ThermalReading])] {
        let byGroup = Dictionary(grouping: readings, by: { group(for: $0) })
        return SensorGroup.allCases.compactMap { g in
            guard let list = byGroup[g], !list.isEmpty else { return nil }
            return (g, list.sorted { $0.displayName < $1.displayName })
        }
    }

    // MARK: - Friendly name mapping
    //
    // Returns a user-facing label for the given raw IOHID `Product` string,
    // or nil if the sensor should be hidden from the UI entirely.
    //
    // Mappings are based on reverse-engineering notes from the `stats` project
    // (Modules/Sensors/values.swift:547-561), the freedomtan iOS HID dump
    // (PMU tdev/tcal/tjunc semantics), and the Asahi Linux project. Unknown
    // names fall through to a lightly-cleaned version of the raw name.
    static func friendlyName(_ raw: String) -> String? {
        // 1. Hide synthetic duplicates emitted by Apple's thermal daemon —
        //    an `Avg:`/`Max:` copy of another sensor is not independent data.
        if raw.hasPrefix("Avg:") || raw.hasPrefix("Max:") { return nil }

        // 2. Hide non-temperature sensors masquerading as temperatures —
        //    `PMU tcal` is a constant calibration reference (~51°C on M2),
        //    community-validated as not a real temperature reading.
        if raw == "PMU tcal" { return nil }

        // 3. Exact-match table — handles special cases.
        switch raw {
        case "gas gauge battery": return "Battery"
        case "PMU tdie":  return "PMIC Die"
        case "PMU tjunc": return "PMIC Die"
        case "Unknown":   return "Unknown"
        default: break
        }

        // 4. Pattern rules for the common `X MTR Temp Sensor N` families and
        //    their siblings. Each entry is (prefix, suffix, template) where
        //    the template's `%d` gets the trailing digit (or nothing if the
        //    raw name has no trailing digit).
        if let n = tailDigit(raw, prefix: "pACC MTR Temp Sensor")  { return "P-Core \(n)" }
        if let n = tailDigit(raw, prefix: "eACC MTR Temp Sensor")  { return "E-Core \(n)" }
        if let n = tailDigit(raw, prefix: "GPU MTR Temp Sensor")   { return "GPU \(n)" }
        if let n = tailDigit(raw, prefix: "SOC MTR Temp Sensor")   { return "SoC Fabric \(n)" }
        if let n = tailDigit(raw, prefix: "ANE MTR Temp Sensor")   { return "Neural Engine \(n)" }
        if let n = tailDigit(raw, prefix: "ISP MTR Temp Sensor")   { return "ISP \(n)" }
        if let n = tailDigit(raw, prefix: "PMGR SOC Die Temp Sensor") { return "SoC Die \(n)" }
        if let n = tailDigit(raw, prefix: "TCC Temp Sensor")       { return "Thermal Zone \(n)" }

        if raw.hasPrefix("NAND CH"), raw.hasSuffix(" temp") {
            // "NAND CH0 temp" -> "SSD Ch 0"
            let inner = raw.dropFirst("NAND CH".count).dropLast(" temp".count)
            if !inner.isEmpty { return "SSD Ch \(inner)" }
        }

        if let n = tailDigit(raw, prefix: "PMU tdie") { return "PMIC Die \(n)" }
        if let n = tailDigit(raw, prefix: "PMU tdev") { return "PMIC Sensor \(n)" }
        if raw.hasPrefix("PMU ") {
            // tcal already handled; everything else (tjunc variants, register-
            // style names like TG0V/TR1F/TP4H, etc.) gets the generic label —
            // Apple does not document which rail each channel sits on and it
            // varies by PMIC revision.
            return "PMIC Sensor"
        }

        // 5. Fallback: strip known noise words, leave the rest for the user.
        var cleaned = raw
        for noise in [" MTR Temp Sensor", " Temp Sensor", " temp"] {
            cleaned = cleaned.replacingOccurrences(of: noise, with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? raw : cleaned
    }

    /// If `raw` starts with `prefix` and the remainder is a non-empty digit
    /// string, returns that digit string; otherwise nil. Used by
    /// `friendlyName` to number per-core/per-channel sensors.
    private static func tailDigit(_ raw: String, prefix: String) -> String? {
        guard raw.hasPrefix(prefix) else { return nil }
        let tail = raw.dropFirst(prefix.count)
        guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(tail)
    }
}
