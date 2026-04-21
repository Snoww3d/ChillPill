import Foundation
import os.log
import ChillPillShared

/// Closed-loop fan controller: reads the selected thermal sensor every
/// `tickInterval` seconds, runs a PI controller, and writes the resulting
/// fan percent to every fan via `Fans.setAllTargets(pct:)`.
///
/// Lifecycle / concurrency contract:
/// - Lives for the life of the helper process. Single instance owned by
///   main.swift, shared across all XPC connections.
/// - All mutable state is accessed only on `SMC.queue`. Callers MUST be
///   running on that queue when they touch `enable`, `disable`, setter
///   methods, or `snapshot()`. The XPC layer already dispatches to
///   `SMC.queue.async` before calling any of those, so that's natural.
/// - The timer handler also runs on `SMC.queue`, so ticks and
///   config-mutations serialize cleanly without extra locks.
///
/// `@unchecked Sendable` because the compiler can't see the queue
/// convention — our thread safety is enforced by the queue discipline
/// above, not by immutability. Captured in a `@Sendable` signal handler
/// block in main.swift.
final class FanController: @unchecked Sendable {
    private let log = OSLog(subsystem: "dev.chillpill", category: "Controller")

    // MARK: - Persisted config (UserDefaults)

    /// Suite-scoped defaults land at
    /// `/var/root/Library/Preferences/dev.chillpill.helper.plist` for a
    /// root-launched daemon. `UserDefaults.standard` here would fall back
    /// to `.GlobalPreferences.plist` because a bare launchd-spawned binary
    /// has no `CFBundleIdentifier` — that would pollute global defaults
    /// and silently break persistence.
    private let defaults: UserDefaults =
        UserDefaults(suiteName: "dev.chillpill.helper") ?? .standard

    private enum Key {
        static let resumeOnLaunch = "ChillPill.Control.ResumeOnLaunch"
        static let sensor         = "ChillPill.Control.Sensor"         // JSON Data
        static let setpoint       = "ChillPill.Control.Setpoint"
        static let preset         = "ChillPill.Control.Preset"         // rawValue
        /// Persisted user intent — only honored at startup when
        /// `resumeOnLaunch` is also true.
        static let enabled        = "ChillPill.Control.Enabled"
    }

    // MARK: - Tuning

    static let tickInterval: TimeInterval = 2.0
    /// Gap that triggers a "skip integral this tick" — covers sleep/wake,
    /// long SMC stalls, debugger pauses. 10 seconds is conservatively >
    /// `tickInterval * 2` but below any plausible thermal transient.
    static let sleepWakeGapThreshold: TimeInterval = 10.0
    /// How many consecutive ticks with no sensor reading before we give up
    /// and fall back to auto. At 2s per tick, 5 ticks = 10s.
    static let sensorMissingTickLimit = 5

    /// Fallback reason surfaced when `Fans.setAllTargets` reports a partial
    /// failure. Kept as a constant so the tick handler's "clear stale
    /// reason" check matches the set path by value, not by copy-paste.
    private static let fanRangeUnknownReason = "one or more fans rejected the target (range unknown)"

    // MARK: - State (access only on SMC.queue)

    private(set) var enabled: Bool = false
    private var resumeOnLaunch: Bool = false
    private var sensor: SensorSelector = .groupMax(.pcore)
    private var setpointCelsius: Double = 75.0
    private var preset: ControlPreset = .balanced

    private var pi: PIController
    private var lastTickUptime: UInt64 = 0
    private var isTicking: Bool = false
    private var missingSensorTicks: Int = 0
    /// `DispatchSourceTimer.activate()` is a one-shot transition from the
    /// never-started state. After the first enable/disable cycle we must
    /// use `resume()` to balance the `suspend()` in `disable`. Tracking
    /// this avoids the trap where a second `enable()` silently no-ops.
    private var timerEverActivated: Bool = false

    /// Last tick's outputs / readings, mirrored into `ControlStateDTO`.
    private var currentReading: Double?
    private var currentError: Double?
    private var lastOutput: Double?
    private var fallbackReason: String?

    private let timer: DispatchSourceTimer

    // MARK: - Init

    /// Loads persisted config and starts the dispatch timer (not yet firing).
    /// Call `resumeIfConfigured()` once at startup — it honors the
    /// `resumeOnLaunch` opt-in and only then flips enabled=true.
    init() {
        // Placeholder kp/ki/setpoint — `applyPreset` + explicit setpoint
        // assignment below establish the real values from loaded config.
        self.pi = PIController(kp: 0, ki: 0, setpoint: 0)
        self.timer = DispatchSource.makeTimerSource(queue: SMC.queue)
        loadConfig()
        applyPreset(preset)
        pi.setpoint = setpointCelsius

        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        // Don't start firing until someone calls enable.
    }

    // MARK: - Public surface (all assume SMC.queue)

    /// Called once on startup. If the user had `resumeOnLaunch=true` AND the
    /// previous run was `enabled=true`, brings the controller back online.
    /// Otherwise leaves it disabled.
    ///
    /// IMPORTANT: the persisted `Enabled` key is cleared unconditionally
    /// first. This way an unclean shutdown (SIGKILL / panic) that leaves
    /// `Enabled=true` on disk can't silently auto-resume on a later launch
    /// when the user flips `resumeOnLaunch=true` in between — which would
    /// violate the safety contract from the plan ("a user who never set
    /// resume-on-launch never auto-enables"). If we do resume, `enable()`
    /// writes `Enabled=true` back.
    func resumeIfConfiguredOnStartup() {
        let wasEnabled = defaults.bool(forKey: Key.enabled)
        persistEnabled(false)  // unconditional clear
        if resumeOnLaunch && wasEnabled {
            os_log("resuming controller from persisted config (setpoint=%.1f sensor=%{public}@ preset=%{public}@)",
                   log: log, type: .info,
                   setpointCelsius, String(describing: sensor), preset.rawValue)
            _ = enable()  // best effort — enable may reject if sensor group currently empty
        }
    }

    @discardableResult
    func enable() -> NSError? {
        if enabled { return nil }
        // Require a readable sensor before turning on — otherwise we'd just
        // trip the missing-sensor fallback on the first tick.
        guard resolveSensorReading() != nil else {
            return chillPillHelperError(.sensorUnavailable,
                "selected sensor group is empty — cannot enable controller")
        }
        enabled = true
        fallbackReason = nil
        missingSensorTicks = 0
        pi.reset()
        lastTickUptime = DispatchTime.now().uptimeNanoseconds
        timer.schedule(deadline: .now() + Self.tickInterval,
                       repeating: Self.tickInterval,
                       leeway: .milliseconds(200))
        if timerEverActivated {
            timer.resume()  // balance the suspend from a previous disable()
        } else {
            timer.activate()
            timerEverActivated = true
        }
        persistEnabled(true)
        os_log("controller enabled", log: log, type: .info)
        return nil
    }

    func disable(reason: String? = nil) {
        guard enabled else { return }
        enabled = false
        fallbackReason = reason
        // Suspend the timer; we'll re-schedule/activate on next enable.
        // DispatchSourceTimer semantics: cancel is one-way, suspend is
        // reversible. Use suspend so we can re-enable cleanly.
        timer.suspend()
        currentReading = nil
        currentError = nil
        lastOutput = nil
        Fans.restoreAllToAuto()
        persistEnabled(false)
        if let reason = reason {
            os_log("controller disabled — %{public}@", log: log, type: .info, reason)
        } else {
            os_log("controller disabled", log: log, type: .info)
        }
    }

    func setSetpoint(_ celsius: Double) -> NSError? {
        guard celsius.isFinite, celsius >= 20, celsius <= 110 else {
            return chillPillHelperError(.invalidSetpoint,
                "setpoint must be finite and in [20, 110] °C")
        }
        setpointCelsius = celsius
        pi.setpoint = celsius
        pi.reset()  // new setpoint, discard accumulated bias
        defaults.set(celsius, forKey: Key.setpoint)
        return nil
    }

    func setSensor(_ selector: SensorSelector) -> NSError? {
        // When the controller is enabled, reject a selector that points at
        // an empty group — consistent with `enable()`'s up-front rejection.
        // When disabled, any valid selector is accepted so the user can
        // pre-configure before flipping enable on.
        let previous = sensor
        sensor = selector
        if enabled, resolveSensorReading() == nil {
            sensor = previous
            return chillPillHelperError(.sensorUnavailable,
                "selected sensor group is empty — keeping previous selection")
        }
        missingSensorTicks = 0
        pi.reset()
        if let data = try? JSONEncoder().encode(selector) {
            defaults.set(data, forKey: Key.sensor)
        }
        return nil
    }

    func setPreset(_ presetName: String) -> NSError? {
        guard let p = ControlPreset(rawValue: presetName) else {
            let valid = ControlPreset.allCases.map(\.rawValue).joined(separator: ", ")
            return chillPillHelperError(.invalidPreset,
                "preset must be one of: \(valid)")
        }
        preset = p
        applyPreset(p)
        pi.reset()
        defaults.set(p.rawValue, forKey: Key.preset)
        return nil
    }

    func setResumeOnLaunch(_ flag: Bool) {
        resumeOnLaunch = flag
        defaults.set(flag, forKey: Key.resumeOnLaunch)
    }

    func snapshot() -> ControlStateDTO {
        ControlStateDTO(
            enabled: enabled,
            resumeOnLaunch: resumeOnLaunch,
            sensor: sensor,
            setpointCelsius: setpointCelsius,
            preset: preset,
            currentReadingCelsius: currentReading,
            currentErrorCelsius: currentError,
            lastOutputPercent: lastOutput,
            fallbackReason: fallbackReason
        )
    }

    // MARK: - Timer tick

    private func tick() {
        // Re-entrancy guard: if a previous tick is still in flight (SMC
        // reads can stall), skip this firing rather than stack work on the
        // queue.
        guard enabled, !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        let now = DispatchTime.now().uptimeNanoseconds
        let dt: Double
        let skipIntegral: Bool
        if lastTickUptime == 0 {
            dt = Self.tickInterval
            skipIntegral = true
        } else {
            dt = Double(now - lastTickUptime) / 1_000_000_000.0
            skipIntegral = dt > Self.sleepWakeGapThreshold
        }
        lastTickUptime = now

        guard let reading = resolveSensorReading() else {
            missingSensorTicks += 1
            if missingSensorTicks >= Self.sensorMissingTickLimit {
                disable(reason: "sensor group went empty for \(missingSensorTicks) ticks")
            }
            currentReading = nil
            currentError = nil
            return
        }
        missingSensorTicks = 0
        currentReading = reading
        currentError = setpointCelsius - reading

        let output = pi.tick(measurement: reading, dt: dt, skipIntegralUpdate: skipIntegral)
        lastOutput = output

        if !Fans.setAllTargets(pct: output) {
            fallbackReason = Self.fanRangeUnknownReason
            os_log("Fans.setAllTargets rejected output %.1f%% — %{public}@",
                   log: log, type: .error, output, fallbackReason ?? "")
            // Don't disable — partial success still cools the machine.
        } else if fallbackReason == Self.fanRangeUnknownReason {
            // Recovered — clear stale reason.
            fallbackReason = nil
        }
    }

    // MARK: - Sensor resolution

    private func resolveSensorReading() -> Double? {
        let temps = Sensors.readThermal()
        let group: SensorGroup
        let useMax: Bool
        switch sensor {
        case .groupMax(let g): group = g; useMax = true
        case .groupAvg(let g): group = g; useMax = false
        }
        // Filter non-finite readings — SMC channels occasionally return NaN
        // on transient glitches. Letting NaN through would poison the
        // integrator state in PIController.
        let values = temps
            .filter { $0.group == group && $0.celsius.isFinite }
            .map { $0.celsius }
        guard !values.isEmpty else { return nil }
        return useMax ? values.max() : values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Presets

    private func applyPreset(_ p: ControlPreset) {
        switch p {
        case .conservative: pi.kp = 2.0; pi.ki = 0.05
        case .balanced:     pi.kp = 4.0; pi.ki = 0.15
        case .aggressive:   pi.kp = 7.0; pi.ki = 0.35
        }
    }

    // MARK: - Persistence

    private func loadConfig() {
        resumeOnLaunch = defaults.bool(forKey: Key.resumeOnLaunch)
        if let data = defaults.data(forKey: Key.sensor),
           let s = try? JSONDecoder().decode(SensorSelector.self, from: data) {
            sensor = s
        }
        let sp = defaults.double(forKey: Key.setpoint)
        if sp.isFinite, sp >= 20, sp <= 110 {
            setpointCelsius = sp
        }
        if let raw = defaults.string(forKey: Key.preset),
           let p = ControlPreset(rawValue: raw) {
            preset = p
        }
    }

    private func persistEnabled(_ flag: Bool) {
        defaults.set(flag, forKey: Key.enabled)
    }
}
