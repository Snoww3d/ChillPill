import Foundation
import ChillPillShared

/// Thin XPC client wrapper around the `ChillPillHelperProtocol`. Manages a
/// single connection to the helper's Mach service, recreating it on
/// invalidation. All replies are delivered on the main queue.
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

    private(set) var lastStatus: Status = .unknown
    private var connection: NSXPCConnection?

    // MARK: - Connection lifecycle

    private func proxy(errorHandler: @escaping (Error) -> Void) -> ChillPillHelperProtocol? {
        if connection == nil {
            let conn = NSXPCConnection(
                machServiceName: ChillPillHelperMachServiceName,
                options: .privileged
            )
            conn.remoteObjectInterface = NSXPCInterface(with: ChillPillHelperProtocol.self)
            conn.invalidationHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.connection = nil
                    self?.lastStatus = .notInstalled
                }
            }
            conn.interruptionHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.connection = nil
                    self?.lastStatus = .notInstalled
                }
            }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler { err in
            DispatchQueue.main.async { errorHandler(err) }
        } as? ChillPillHelperProtocol
    }

    private func onMain<T>(_ value: T, _ callback: @escaping (T) -> Void) {
        DispatchQueue.main.async { callback(value) }
    }

    // MARK: - Reads

    func ping(completion: @escaping (String?) -> Void) {
        guard let p = proxy(errorHandler: { _ in
            self.lastStatus = .notInstalled
            self.onMain(nil, completion)
        }) else {
            lastStatus = .notInstalled
            onMain(nil, completion)
            return
        }
        p.ping { [weak self] version in
            self?.lastStatus = .running
            self?.onMain(version, completion)
        }
    }

    func fans(completion: @escaping ([FanDTO]) -> Void) {
        guard let p = proxy(errorHandler: { [weak self] err in
            self?.lastStatus = .error(err.localizedDescription)
            self?.onMain([], completion)
        }) else {
            lastStatus = .notInstalled
            onMain([], completion)
            return
        }
        p.fans { [weak self] data, err in
            guard let data = data, err == nil,
                  let list = try? JSONDecoder().decode([FanDTO].self, from: data) else {
                self?.lastStatus = .error(err?.localizedDescription ?? "bad fans payload")
                self?.onMain([], completion)
                return
            }
            self?.lastStatus = .running
            self?.onMain(list, completion)
        }
    }

    func temperatures(completion: @escaping ([TemperatureDTO]) -> Void) {
        guard let p = proxy(errorHandler: { [weak self] err in
            self?.lastStatus = .error(err.localizedDescription)
            self?.onMain([], completion)
        }) else {
            lastStatus = .notInstalled
            onMain([], completion)
            return
        }
        p.temperatures { [weak self] data, err in
            guard let data = data, err == nil,
                  let list = try? JSONDecoder().decode([TemperatureDTO].self, from: data) else {
                self?.lastStatus = .error(err?.localizedDescription ?? "bad temps payload")
                self?.onMain([], completion)
                return
            }
            self?.lastStatus = .running
            self?.onMain(list, completion)
        }
    }

    // MARK: - Writes

    func setFanAuto(index: Int, completion: @escaping (String?) -> Void) {
        guard let p = proxy(errorHandler: { [weak self] err in
            self?.lastStatus = .error(err.localizedDescription)
            self?.onMain(err.localizedDescription, completion)
        }) else {
            onMain("Helper not running", completion)
            return
        }
        p.setFanAuto(index: index) { [weak self] err in
            self?.onMain(err?.localizedDescription, completion)
        }
    }

    func setFanTarget(index: Int, rpm: Double, completion: @escaping (String?) -> Void) {
        guard let p = proxy(errorHandler: { [weak self] err in
            self?.lastStatus = .error(err.localizedDescription)
            self?.onMain(err.localizedDescription, completion)
        }) else {
            onMain("Helper not running", completion)
            return
        }
        p.setFanTarget(index: index, rpm: rpm) { [weak self] err in
            self?.onMain(err?.localizedDescription, completion)
        }
    }

    func setAllFansAuto(completion: @escaping (String?) -> Void) {
        guard let p = proxy(errorHandler: { [weak self] err in
            self?.lastStatus = .error(err.localizedDescription)
            self?.onMain(err.localizedDescription, completion)
        }) else {
            onMain("Helper not running", completion)
            return
        }
        p.setAllFansAuto { [weak self] err in
            self?.onMain(err?.localizedDescription, completion)
        }
    }

    func setAllFansTarget(pct: Double, completion: @escaping (String?) -> Void) {
        guard let p = proxy(errorHandler: { [weak self] err in
            self?.lastStatus = .error(err.localizedDescription)
            self?.onMain(err.localizedDescription, completion)
        }) else {
            onMain("Helper not running", completion)
            return
        }
        p.setAllFansTarget(pct: pct) { [weak self] err in
            self?.onMain(err?.localizedDescription, completion)
        }
    }

    func prepareForShutdown(completion: @escaping (String?) -> Void) {
        guard let p = proxy(errorHandler: { err in
            self.onMain(err.localizedDescription, completion)
        }) else {
            onMain(nil, completion)  // helper not running is fine on shutdown
            return
        }
        p.prepareForShutdown { [weak self] err in
            self?.onMain(err?.localizedDescription, completion)
        }
    }
}
