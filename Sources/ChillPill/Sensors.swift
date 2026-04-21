import Foundation
import CChillPillIOKit

struct ThermalReading {
    let name: String
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
            let name = (IOHIDServiceClientCopyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String) ?? "Unknown"
            guard let event = IOHIDServiceClientCopyEvent(
                service,
                eventTypeTemperature,
                0,
                0
            )?.takeRetainedValue() else { continue }
            let value = IOHIDEventGetFloatValue(event, fieldTemperatureLevel)
            if value.isFinite && value > -50 && value < 150 {
                readings.append(ThermalReading(name: name, celsius: value))
            }
        }
        return readings.sorted { $0.name < $1.name }
    }

    /// Best-effort "CPU hot spot" — max of sensors whose name suggests CPU/SoC/die.
    static func hottestCPU(_ readings: [ThermalReading]) -> ThermalReading? {
        let cpuish = readings.filter { group(for: $0) == .cpu }
        return (cpuish.isEmpty ? readings : cpuish).max { $0.celsius < $1.celsius }
    }

    /// Heuristically classify a thermal sensor by name. Keywords are
    /// lower-cased and checked in priority order so, e.g., an "SSD CPU
    /// controller" ends up in .storage rather than .cpu. Order of the
    /// `case` arms matters.
    static func group(for reading: ThermalReading) -> SensorGroup {
        let n = reading.name.lowercased()
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
            return (g, list.sorted { $0.name < $1.name })
        }
    }
}
