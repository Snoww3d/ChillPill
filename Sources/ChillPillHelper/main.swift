import Foundation
import os.log
import ChillPillShared

/// ChillPillHelper — privileged daemon that owns SMC reads/writes and
/// thermal sensor enumeration. Registered by the UI app via
/// `SMAppService.daemon(plistName:)`; runs under launchd as root; talks to
/// the UI over a single Mach XPC listener.

let log = OSLog(subsystem: "dev.chillpill", category: "Helper")

/// NSXPCListenerDelegate that vends the HelperImpl object for each new
/// connection, constraining the exported interface to the shared protocol.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let impl: HelperImpl

    init(impl: HelperImpl) {
        self.impl = impl
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ChillPillHelperProtocol.self)
        newConnection.exportedObject = impl
        newConnection.resume()
        return true
    }
}

// MARK: - Graceful shutdown
//
// launchd can SIGTERM the helper at any time (user toggles it off in Login
// Items, system shutdown, etc.). Restore all fans to auto first so we don't
// leave the hardware in forced mode when the helper disappears.

func installSignalHandlers() {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    let handler: @Sendable () -> Void = {
        // sync on SMC.queue so any in-flight XPC-driven SMC transaction
        // finishes before we restore-to-auto and exit. This matters: the
        // signal handler would otherwise race concurrent setFanTarget
        // calls hitting the same `AppleSMC` userclient.
        SMC.queue.sync {
            Fans.restoreAllToAuto()
        }
        exit(0)
    }
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler(handler: handler)
    term.resume()
    signalSources.append(term)

    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler(handler: handler)
    sigint.resume()
    signalSources.append(sigint)
}

// Retain the sources globally so they stay alive past main().
var signalSources: [DispatchSourceSignal] = []

// MARK: - Entry point

let version = "0.1.0"
os_log("ChillPillHelper starting (version %{public}@)", log: log, type: .info, version)

installSignalHandlers()

let impl = HelperImpl(version: version)
let delegate = HelperListenerDelegate(impl: impl)
let listener = NSXPCListener(machServiceName: ChillPillHelperMachServiceName)
listener.delegate = delegate
listener.resume()

os_log("XPC listener on %{public}@ is up", log: log, type: .info, ChillPillHelperMachServiceName)

// launchd-managed daemons run indefinitely — block the main thread.
dispatchMain()
