import Foundation
import ChillPillShared

/// Concrete implementation of the XPC protocol. Every method validates its
/// input before touching SMC and returns a descriptive `NSError` on failure
/// so the UI can show something better than a generic "it failed".
final class HelperImpl: NSObject, ChillPillHelperProtocol {

    private let version: String

    init(version: String) {
        self.version = version
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("ChillPillHelper/\(version)")
    }

    func fans(reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let list = Fans.readAll()
            let data = try JSONEncoder().encode(list)
            reply(data, nil)
        } catch {
            reply(nil, chillPillHelperError(.internalFailure,
                                            "fans encode: \(error.localizedDescription)"))
        }
    }

    func temperatures(reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let list = Sensors.readThermal()
            let data = try JSONEncoder().encode(list)
            reply(data, nil)
        } catch {
            reply(nil, chillPillHelperError(.internalFailure,
                                            "temperatures encode: \(error.localizedDescription)"))
        }
    }

    func setFanAuto(index: Int, reply: @escaping (NSError?) -> Void) {
        guard (0..<Fans.count()).contains(index) else {
            reply(chillPillHelperError(.invalidIndex, "fan index \(index) out of range"))
            return
        }
        if Fans.setAuto(index) {
            reply(nil)
        } else {
            reply(chillPillHelperError(.smcWriteFailed, "SMC rejected F\(index)Md = 0"))
        }
    }

    func setFanTarget(index: Int, rpm: Double, reply: @escaping (NSError?) -> Void) {
        guard (0..<Fans.count()).contains(index) else {
            reply(chillPillHelperError(.invalidIndex, "fan index \(index) out of range"))
            return
        }
        guard rpm.isFinite else {
            reply(chillPillHelperError(.invalidRPM, "rpm must be a finite number"))
            return
        }
        // Fans.setTarget clamps into the advertised range and rolls back on
        // partial failure. It returns false if the fan's range is unknown.
        if Fans.setTarget(index, rpm: rpm) {
            reply(nil)
        } else {
            reply(chillPillHelperError(.rangeUnknown,
                                       "could not apply target \(Int(rpm)) RPM to fan \(index)"))
        }
    }

    func setAllFansAuto(reply: @escaping (NSError?) -> Void) {
        Fans.restoreAllToAuto()
        reply(nil)
    }

    func setAllFansTarget(pct: Double, reply: @escaping (NSError?) -> Void) {
        guard pct.isFinite else {
            reply(chillPillHelperError(.invalidRPM, "pct must be a finite number"))
            return
        }
        if Fans.setAllTargets(pct: pct) {
            reply(nil)
        } else {
            reply(chillPillHelperError(.smcWriteFailed,
                                       "at least one fan rejected the \(Int(pct))% target"))
        }
    }

    func prepareForShutdown(reply: @escaping (NSError?) -> Void) {
        Fans.restoreAllToAuto()
        reply(nil)
    }
}
