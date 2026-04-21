import Foundation
import CChillPillIOKit

struct ThermalReading {
    let name: String
    let celsius: Double
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
        let cpuish = readings.filter {
            let n = $0.name.lowercased()
            return n.contains("cpu") || n.contains("pmp") || n.contains("soc")
                || n.contains("pecpu") || n.contains("ecpu")
        }
        return (cpuish.isEmpty ? readings : cpuish).max { $0.celsius < $1.celsius }
    }
}
