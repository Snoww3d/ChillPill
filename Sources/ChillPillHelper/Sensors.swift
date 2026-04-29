import Foundation
import CChillPillIOKit
import ChillPillShared

enum Sensors {
    /// HID usage page / usage identifying Apple thermal sensors.
    /// 0xFF00 = kHIDPage_AppleVendor, 0x0005 = temperature sensor.
    private static let usagePage: Int32 = 0xFF00
    private static let usage: Int32 = 0x0005

    /// Event type 15 = kIOHIDEventTypeTemperature; field = type << 16.
    private static let eventTypeTemperature: Int64 = 15
    private static let fieldTemperatureLevel: Int32 = 15 << 16

    // MARK: - Reading filters
    //
    // Two predicates with deliberately different lower bounds. Keeping them
    // named (rather than as duplicated inline expressions) so a future
    // "DRY this up" pass doesn't quietly reunify them and reintroduce the
    // zero-skew bug this asymmetry exists to fix.

    /// Per-cycle filter — admits a read into the DTO list as a real
    /// measurement *right now*. Drops the canonical "sensor not populated"
    /// sentinel of 0.0 used by HID and SMC for absent / unplugged probes
    /// (e.g. battery on a desktop, charger when unplugged). Letting zeros
    /// through skews every `groupAvg` consumer: the menu-bar display
    /// picker, the Temperatures-section averages, and the controller's
    /// avg sensor mode.
    ///
    /// Known accepted trade: a Mac genuinely operating below ~1°C ambient
    /// will see its `Ts*` / `TaLP` / `TA*P` ambient/skin/palm probes also
    /// dropped. Treating "below freezing" as out-of-scope for this app.
    private static func isLiveReading(_ v: Double) -> Bool {
        v.isFinite && v > 0 && v < 150
    }

    /// Cache-discovery filter — admits an SMC key into `smcCache` as a
    /// plausible temperature sensor. Looser than `isLiveReading` on the
    /// low end so a probe that happens to read exactly 0.0 at boot
    /// (battery probe before charge cycle, charger before plug-in) still
    /// gets cached and can become live on a later cycle. Cost: a handful
    /// of permanently-zero probes on desktops cause O(K) wasted SMC reads
    /// per refresh; SMC reads are microsecond-cheap so we don't bother
    /// with soft eviction.
    private static func isPlausibleTemperature(_ v: Double) -> Bool {
        v.isFinite && v > -50 && v < 150
    }

    /// Merged HID + SMC readings, de-duplicated by display name.
    static func readThermal() -> [TemperatureDTO] {
        var readings = readHIDTemperatures()
        let seen = Set(readings.map { $0.displayName })
        for smc in readSMCTemperatures() where !seen.contains(smc.displayName) {
            readings.append(smc)
        }
        return readings.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - HID (per-die / per-block)

    private static func readHIDTemperatures() -> [TemperatureDTO] {
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

        var out: [TemperatureDTO] = []
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
            if isLiveReading(value) {
                out.append(TemperatureDTO(
                    rawName: raw, displayName: display, celsius: value,
                    group: group(forRawName: raw)))
            }
        }
        return out
    }

    // MARK: - SMC (board-level / location-based)

    private static var smcCache: [SMC.DiscoveredKey]?

    private static let temperatureDataTypes: Set<String> = [
        "sp78", "sp87", "sp96", "sp69", "flt ", "fpe2", "fp1f"
    ]

    private static func readSMCTemperatures() -> [TemperatureDTO] {
        let candidates = cachedSMCTemperatureKeys()
        var out: [TemperatureDTO] = []
        for k in candidates {
            guard let display = smcFriendlyName(k.key) else { continue }
            guard let value = SMC.shared.readWithInfo(k.key, info: k.info)
                .flatMap({ SMC.decode($0) }) else { continue }
            guard isLiveReading(value) else { continue }
            out.append(TemperatureDTO(
                rawName: k.key, displayName: display, celsius: value,
                group: group(forRawName: k.key)))
        }
        return out
    }

    private static func cachedSMCTemperatureKeys() -> [SMC.DiscoveredKey] {
        if let cached = smcCache { return cached }
        let all = SMC.shared.discoverAllKeys()
        let filtered = all.filter { k in
            guard k.key.hasPrefix("T"), k.key.count == 4 else { return false }
            guard temperatureDataTypes.contains(k.info.dataType) else { return false }
            guard let v = SMC.shared.readWithInfo(k.key, info: k.info)
                .flatMap({ SMC.decode($0) }) else { return false }
            return isPlausibleTemperature(v)
        }
        smcCache = filtered
        return filtered
    }

    // MARK: - Classification

    static func group(forRawName raw: String) -> SensorGroup {
        // SMC FourCC: exactly 4 chars, starts with 'T'.
        if raw.count == 4, raw.hasPrefix("T") {
            return smcGroup(fourCC: raw) ?? .other
        }

        let n = raw.lowercased()
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
        // M-series cluster sensors first — order matters: "pACC" must match
        // before the generic "cpu" test, and "pecpu" contains "ecpu" so
        // check that distinct pair before the looser keyword set.
        if n.contains("pacc") || n.contains("pcpu") {
            return .pcore
        }
        if n.contains("eacc") || n.contains("ecpu") || n.contains("pecpu") {
            return .ecore
        }
        // SoC-wide sensors: PMGR die, SOC fabric, efuse, PMP die.
        if n.contains("soc") || n.contains("pmgr") || n.contains("pmp")
            || n.contains("efuse") {
            return .soc
        }
        // Catch-all CPU: Intel-era / miscellaneous core-adjacent sensors.
        if n.contains("cpu") {
            return .cpu
        }
        if n.contains("dram") || n.contains("memory") || n.contains("mem ") {
            return .memory
        }
        return .other
    }

    private static func smcGroup(fourCC key: String) -> SensorGroup? {
        guard key.count == 4, key.hasPrefix("T") else { return nil }
        let chars = Array(key)
        switch chars[1] {
        case "B", "b":        return .battery
        // `Tp*` on Apple Silicon = P-core cluster readings; on Intel it's
        // historically CPU package. `.pcore` is the better default — Intel
        // users will see it in P-Cores which is still correct.
        case "p":             return .pcore
        case "e":             return .ecore
        // `TC*` is generic CPU (package / proximity / uncore) and `TN*` is
        // MCP / north-bridge — both better live in SoC on M-series, with
        // .cpu as an Intel-era fallback. We default to .cpu because a plain
        // TC0P on Intel is definitely CPU proximity, not SoC.
        case "C", "P":        return .cpu
        case "N":             return .soc
        case "G", "g":        return .gpu
        case "H", "h":        return .storage
        case "M", "m":        return .memory
        case "A", "a":        return .ambient
        case "s":             return .ambient
        case "W", "w":        return .other
        case "f":             return .other
        case "S":             return .other
        default:              return .other
        }
    }

    // MARK: - Friendly name: HID

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

    // MARK: - Friendly name: SMC

    static func smcFriendlyName(_ key: String) -> String? {
        switch key {
        case "TB0T", "TB1T", "TB2T", "TB3T":   return nil
        case "TH0x":                           return nil
        default: break
        }

        // Note: we used to suppress `Tp*`/`Te*`/`Tg*` here to avoid visible
        // overlap with HID `pACC`/`eACC`/`GPU MTR` names. But on Macs where
        // HID doesn't surface those per-cluster labels, suppressing left the
        // P-Cores / E-Cores groups empty. Let SMC names flow through — the
        // `displayName` dedup in `readThermal()` still collapses true dupes,
        // and `"SMC Tp01"` (default SMC name) doesn't collide with `"P-Core 1"`.

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
        case "Tfin", "Tf0F": return "Heatsink"
        default: break
        }

        return "SMC \(key)"
    }

    private static func tailDigit(_ raw: String, prefix: String) -> String? {
        guard raw.hasPrefix(prefix) else { return nil }
        let tail = raw.dropFirst(prefix.count)
        guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(tail)
    }
}
