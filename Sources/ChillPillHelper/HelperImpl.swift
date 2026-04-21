import Foundation
import ChillPillShared

/// Concrete implementation of the XPC protocol. Every method validates its
/// input before touching SMC and returns a descriptive `NSError` on failure
/// so the UI can show something better than a generic "it failed".
///
/// All SMC access is serialized through `smcQueue`. NSXPCListener can dispatch
/// concurrent incoming requests across its own queues, and the single
/// `AppleSMC` userclient is not safe to hammer from multiple threads — one
/// open call racing another would leak userclients or read half-open state.
/// Holding method bodies on a single serial queue also means
/// `Fans.setTarget`'s read-then-write sequences are atomic from any client's
/// perspective.
final class HelperImpl: NSObject, ChillPillHelperProtocol {

    private let version: String
    private let smcQueue = DispatchQueue(label: "dev.chillpill.helper.smc")

    init(version: String) {
        self.version = version
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("ChillPillHelper/\(version)")
    }

    func fans(reply: @escaping (Data?, NSError?) -> Void) {
        smcQueue.async {
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
        smcQueue.async {
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
        smcQueue.async {
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
    }

    func setFanTarget(index: Int, rpm: Double, reply: @escaping (NSError?) -> Void) {
        smcQueue.async {
            guard (0..<Fans.count()).contains(index) else {
                reply(chillPillHelperError(.invalidIndex, "fan index \(index) out of range"))
                return
            }
            guard rpm.isFinite else {
                reply(chillPillHelperError(.invalidRPM, "rpm must be a finite number"))
                return
            }
            if Fans.setTarget(index, rpm: rpm) {
                reply(nil)
            } else {
                reply(chillPillHelperError(.rangeUnknown,
                                           "could not apply target \(Int(rpm)) RPM to fan \(index)"))
            }
        }
    }

    func setAllFansAuto(reply: @escaping (NSError?) -> Void) {
        smcQueue.async {
            Fans.restoreAllToAuto()
            reply(nil)
        }
    }

    func setAllFansTarget(pct: Double, reply: @escaping (NSError?) -> Void) {
        smcQueue.async {
            guard pct.isFinite else {
                reply(chillPillHelperError(.invalidRPM, "pct must be a finite number"))
                return
            }
            if Fans.setAllTargets(pct: pct) {
                reply(nil)
            } else {
                reply(chillPillHelperError(.rangeUnknown,
                                           "at least one fan rejected the \(Int(pct))% target (range unknown or write failed)"))
            }
        }
    }

    func prepareForShutdown(reply: @escaping (NSError?) -> Void) {
        smcQueue.async {
            Fans.restoreAllToAuto()
            reply(nil)
        }
    }
}
