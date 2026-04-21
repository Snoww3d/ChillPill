import Foundation
import ChillPillShared

/// Thin XPC client wrapper around the `ChillPillHelperProtocol`. Manages a
/// single connection to the helper's Mach service, recreating it on
/// invalidation. Thread-safe: callers may invoke from any queue; all
/// completion handlers are delivered on the main queue.
final class HelperClient {
    static let shared = HelperClient()

    private init() {}

    /// What the UI should show if something's off with the helper.
    enum Status: Equatable {
        case unknown
        case running
        case notInstalled   // no connection / Mach service missing
        case error(String)
    }

    /// NSLock protects `_connection` and `_lastStatus`. The NSXPCConnection's
    /// invalidation/interruption handlers run on the framework's private
    /// queue; without this lock, they could race the main-thread
    /// `proxy(...)` calls and hand out stale proxies.
    private let lock = NSLock()
    private var _connection: NSXPCConnection?
    private var _lastStatus: Status = .unknown

    var lastStatus: Status {
        lock.lock(); defer { lock.unlock() }
        return _lastStatus
    }

    private func setStatus(_ status: Status) {
        lock.lock()
        _lastStatus = status
        lock.unlock()
    }

    // MARK: - Connection lifecycle

    private func proxy(errorHandler: @escaping (Error) -> Void) -> ChillPillHelperProtocol? {
        lock.lock()
        if _connection == nil {
            let conn = NSXPCConnection(
                machServiceName: ChillPillHelperMachServiceName,
                options: .privileged
            )
            conn.remoteObjectInterface = NSXPCInterface(with: ChillPillHelperProtocol.self)
            let tearDown: () -> Void = { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self._connection = nil
                self._lastStatus = .notInstalled
                self.lock.unlock()
            }
            conn.invalidationHandler = tearDown
            conn.interruptionHandler = tearDown
            conn.resume()
            _connection = conn
        }
        let handle = _connection
        lock.unlock()

        return handle?.remoteObjectProxyWithErrorHandler { err in
            DispatchQueue.main.async { errorHandler(err) }
        } as? ChillPillHelperProtocol
    }

    private func onMain<T>(_ value: T, _ callback: @escaping (T) -> Void) {
        DispatchQueue.main.async { callback(value) }
    }

    // MARK: - Reads

    func ping(completion: @escaping (String?) -> Void) {
        guard let p = proxy(errorHandler: { _ in
            self.setStatus(.notInstalled)
            self.onMain(nil, completion)
        }) else {
            setStatus(.notInstalled)
            onMain(nil, completion)
            return
        }
        p.ping { [weak self] version in
            self?.setStatus(.running)
            self?.onMain(version, completion)
        }
    }

    func fans(completion: @escaping ([FanDTO]) -> Void) {
        guard let p = proxy(errorHandler: { [weak self] err in
            self?.setStatus(.error(err.localizedDescription))
            self?.onMain([], completion)
        }) else {
            setStatus(.notInstalled)
            onMain([], completion)
            return
        }
        p.fans { [weak self] data, err in
            guard let data = data, err == nil,
                  let list = try? JSONDecoder().decode([FanDTO].self, from: data) else {
                self?.setStatus(.error(err?.localizedDescription ?? "bad fans payload"))
                self?.onMain([], completion)
                return
            }
            self?.setStatus(.running)
            self?.onMain(list, completion)
        }
    }

    func temperatures(completion: @escaping ([TemperatureDTO]) -> Void) {
        guard let p = proxy(errorHandler: { [weak self] err in
            self?.setStatus(.error(err.localizedDescription))
            self?.onMain([], completion)
        }) else {
            setStatus(.notInstalled)
            onMain([], completion)
            return
        }
        p.temperatures { [weak self] data, err in
            guard let data = data, err == nil,
                  let list = try? JSONDecoder().decode([TemperatureDTO].self, from: data) else {
                self?.setStatus(.error(err?.localizedDescription ?? "bad temps payload"))
                self?.onMain([], completion)
                return
            }
            self?.setStatus(.running)
            self?.onMain(list, completion)
        }
    }

    // MARK: - Writes

    func setFanAuto(index: Int, completion: @escaping (NSError?) -> Void) {
        writeCall(completion: completion) { proxy, reply in
            proxy.setFanAuto(index: index, reply: reply)
        }
    }

    func setFanTarget(index: Int, rpm: Double, completion: @escaping (NSError?) -> Void) {
        writeCall(completion: completion) { proxy, reply in
            proxy.setFanTarget(index: index, rpm: rpm, reply: reply)
        }
    }

    func setAllFansAuto(completion: @escaping (NSError?) -> Void) {
        writeCall(completion: completion) { proxy, reply in
            proxy.setAllFansAuto(reply: reply)
        }
    }

    func setAllFansTarget(pct: Double, completion: @escaping (NSError?) -> Void) {
        writeCall(completion: completion) { proxy, reply in
            proxy.setAllFansTarget(pct: pct, reply: reply)
        }
    }

    /// Best-effort tell the helper to restore all fans to auto. Fire-and-forget;
    /// callers MUST NOT block the main queue waiting for the reply (the reply
    /// itself is dispatched to main and would deadlock). The helper runs its
    /// own SIGTERM/SIGINT handler that restores auto, so this XPC call is a
    /// secondary safety net.
    func prepareForShutdown() {
        guard let p = proxy(errorHandler: { _ in }) else { return }
        p.prepareForShutdown { _ in }
    }

    // MARK: - Target-temperature controller (issue #10)

    func getControlState(completion: @escaping (ControlStateDTO?) -> Void) {
        guard let p = proxy(errorHandler: { [weak self] err in
            self?.setStatus(.error(err.localizedDescription))
            self?.onMain(nil, completion)
        }) else {
            setStatus(.notInstalled)
            onMain(nil, completion)
            return
        }
        p.getControlState { [weak self] data, err in
            guard let data = data, err == nil,
                  let state = try? JSONDecoder().decode(ControlStateDTO.self, from: data) else {
                self?.setStatus(.error(err?.localizedDescription ?? "bad control-state payload"))
                self?.onMain(nil, completion)
                return
            }
            self?.setStatus(.running)
            self?.onMain(state, completion)
        }
    }

    func setControlEnabled(_ enabled: Bool, completion: @escaping (NSError?) -> Void) {
        writeCall(completion: completion) { proxy, reply in
            proxy.setControlEnabled(enabled, reply: reply)
        }
    }

    func setControlSetpoint(_ celsius: Double, completion: @escaping (NSError?) -> Void) {
        writeCall(completion: completion) { proxy, reply in
            proxy.setControlSetpoint(celsius, reply: reply)
        }
    }

    func setControlSensor(_ selector: SensorSelector, completion: @escaping (NSError?) -> Void) {
        let data: Data
        do {
            data = try JSONEncoder().encode(selector)
        } catch {
            onMain(chillPillHelperError(.invalidSensor,
                "encode SensorSelector: \(error.localizedDescription)"),
                completion)
            return
        }
        writeCall(completion: completion) { proxy, reply in
            proxy.setControlSensor(selectorData: data, reply: reply)
        }
    }

    func setControlPreset(_ preset: ControlPreset, completion: @escaping (NSError?) -> Void) {
        writeCall(completion: completion) { proxy, reply in
            proxy.setControlPreset(preset.rawValue, reply: reply)
        }
    }

    func setControlResumeOnLaunch(_ flag: Bool, completion: @escaping (NSError?) -> Void) {
        writeCall(completion: completion) { proxy, reply in
            proxy.setControlResumeOnLaunch(flag, reply: reply)
        }
    }

    // MARK: - Helpers

    private func writeCall(
        completion: @escaping (NSError?) -> Void,
        _ body: @escaping (ChillPillHelperProtocol, @escaping (NSError?) -> Void) -> Void
    ) {
        guard let p = proxy(errorHandler: { [weak self] err in
            self?.setStatus(.error(err.localizedDescription))
            self?.onMain(err as NSError, completion)
        }) else {
            onMain(
                NSError(
                    domain: ChillPillHelperErrorDomain,
                    code: ChillPillHelperErrorCode.notAuthorized.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Helper not running"]
                ),
                completion
            )
            return
        }
        body(p) { [weak self] err in
            self?.onMain(err, completion)
        }
    }
}
