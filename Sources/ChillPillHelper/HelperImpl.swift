import Foundation
import ChillPillShared

/// Concrete implementation of the XPC protocol. Every method validates its
/// input before touching SMC and returns a descriptive `NSError` on failure
/// so the UI can show something better than a generic "it failed".
///
/// All SMC access is serialized through `SMC.queue` (shared across every
/// caller — XPC methods here, and the signal handler in `main.swift`).
/// NSXPCListener can dispatch concurrent incoming requests across its own
/// threads, and the single `AppleSMC` userclient is not safe to hammer
/// from multiple threads.
final class HelperImpl: NSObject, ChillPillHelperProtocol {

    private let version: String
    private let controller: FanController

    init(version: String, controller: FanController) {
        self.version = version
        self.controller = controller
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("ChillPillHelper/\(version)")
    }

    func fans(reply: @escaping (Data?, NSError?) -> Void) {
        SMC.queue.async {
            do {
                let list = Fans.readAll()
                let data = try JSONEncoder().encode(list)
                reply(data, nil)
            } catch {
                reply(nil, chillPillHelperError(.internalFailure,
                                                "fans encode: \(error.localizedDescription)"))
            }
        }
    }

    func temperatures(reply: @escaping (Data?, NSError?) -> Void) {
        SMC.queue.async {
            do {
                let list = Sensors.readThermal()
                let data = try JSONEncoder().encode(list)
                reply(data, nil)
            } catch {
                reply(nil, chillPillHelperError(.internalFailure,
                                                "temperatures encode: \(error.localizedDescription)"))
            }
        }
    }

    func setFanAuto(index: Int, reply: @escaping (NSError?) -> Void) {
        SMC.queue.async {
            guard (0..<Fans.count()).contains(index) else {
                reply(chillPillHelperError(.invalidIndex, "fan index \(index) out of range"))
                return
            }
            // Manual-override mutex: any explicit fan write disables the
            // auto-tracking controller first so the two don't fight.
            self.controller.disable(reason: "user set fan \(index) to auto")
            if Fans.setAuto(index) {
                reply(nil)
            } else {
                reply(chillPillHelperError(.smcWriteFailed, "SMC rejected F\(index)Md = 0"))
            }
        }
    }

    func setFanTarget(index: Int, rpm: Double, reply: @escaping (NSError?) -> Void) {
        SMC.queue.async {
            guard (0..<Fans.count()).contains(index) else {
                reply(chillPillHelperError(.invalidIndex, "fan index \(index) out of range"))
                return
            }
            guard rpm.isFinite else {
                reply(chillPillHelperError(.invalidRPM, "rpm must be a finite number"))
                return
            }
            self.controller.disable(reason: "user set fan \(index) target RPM")
            if Fans.setTarget(index, rpm: rpm) {
                reply(nil)
            } else {
                reply(chillPillHelperError(.rangeUnknown,
                                           "could not apply target \(Int(rpm)) RPM to fan \(index)"))
            }
        }
    }

    func setAllFansAuto(reply: @escaping (NSError?) -> Void) {
        SMC.queue.async {
            self.controller.disable(reason: "user set all fans to auto")
            Fans.restoreAllToAuto()
            reply(nil)
        }
    }

    func setAllFansTarget(pct: Double, reply: @escaping (NSError?) -> Void) {
        SMC.queue.async {
            guard pct.isFinite else {
                reply(chillPillHelperError(.invalidRPM, "pct must be a finite number"))
                return
            }
            self.controller.disable(reason: "user set all fans to \(Int(pct))%")
            if Fans.setAllTargets(pct: pct) {
                reply(nil)
            } else {
                reply(chillPillHelperError(.rangeUnknown,
                                           "at least one fan rejected the \(Int(pct))% target (range unknown or write failed)"))
            }
        }
    }

    func prepareForShutdown(reply: @escaping (NSError?) -> Void) {
        SMC.queue.async {
            self.controller.disable(reason: "prepareForShutdown")
            Fans.restoreAllToAuto()
            reply(nil)
        }
    }

    // MARK: - Target-temperature controller (issue #10)

    func getControlState(reply: @escaping (Data?, NSError?) -> Void) {
        SMC.queue.async {
            do {
                let data = try JSONEncoder().encode(self.controller.snapshot())
                reply(data, nil)
            } catch {
                reply(nil, chillPillHelperError(.internalFailure,
                    "getControlState encode: \(error.localizedDescription)"))
            }
        }
    }

    func setControlEnabled(_ enabled: Bool, reply: @escaping (NSError?) -> Void) {
        SMC.queue.async {
            if enabled {
                reply(self.controller.enable())
            } else {
                self.controller.disable(reason: "user disabled controller")
                reply(nil)
            }
        }
    }

    func setControlSetpoint(_ celsius: Double, reply: @escaping (NSError?) -> Void) {
        SMC.queue.async { reply(self.controller.setSetpoint(celsius)) }
    }

    func setControlSensor(selectorData: Data, reply: @escaping (NSError?) -> Void) {
        // Bound the decode input so a misbehaving UI can't stall the SMC
        // queue with an oversize blob. SensorSelector encodes to <100 bytes.
        guard selectorData.count <= 1024 else {
            reply(chillPillHelperError(.invalidSensor,
                "selectorData too large (\(selectorData.count) bytes; max 1024)"))
            return
        }
        SMC.queue.async {
            do {
                let selector = try JSONDecoder().decode(SensorSelector.self, from: selectorData)
                reply(self.controller.setSensor(selector))
            } catch {
                reply(chillPillHelperError(.invalidSensor,
                    "SensorSelector decode: \(error.localizedDescription)"))
            }
        }
    }

    func setControlPreset(_ presetName: String, reply: @escaping (NSError?) -> Void) {
        SMC.queue.async { reply(self.controller.setPreset(presetName)) }
    }

    func setControlResumeOnLaunch(_ enabled: Bool, reply: @escaping (NSError?) -> Void) {
        SMC.queue.async {
            self.controller.setResumeOnLaunch(enabled)
            reply(nil)
        }
    }
}
