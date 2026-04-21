import Foundation

/// Pure PI controller — no SMC, no XPC, no side effects. A single `tick(…)`
/// call takes the latest measurement and elapsed `dt`, updates integrator
/// state, and returns a clamped output in `[outputMin, outputMax]`.
///
/// Conventions:
/// - `error = setpoint - measurement`. Positive error → measurement is low →
///   controller wants less cooling (lower fan percent).
///   Negative error → measurement is above setpoint → more cooling.
/// - Output sign is flipped relative to error so that "hotter than setpoint"
///   produces a LARGER fan percent. Concretely:
///   `output = -kp * error - ki * integral`.
/// - Anti-windup uses **conditional integration**: we only accumulate the
///   integral when the unclamped output is within `[outputMin, outputMax]`,
///   OR when continuing to integrate would *reduce* saturation. The
///   integrator state itself is also clamped to `[integralMin, integralMax]`
///   so a resume-from-cold doesn't take minutes to wind down.
///
/// Pure — no I/O — so unit-testable in isolation. Lives in `ChillPillShared`
/// (rather than the helper) purely so the test target can reach it without
/// needing `@testable import` on an executable target.
public struct PIController {
    public var kp: Double
    public var ki: Double
    public var setpoint: Double

    public var integral: Double = 0
    public var outputMin: Double = 0
    public var outputMax: Double = 100
    /// Bounds on the integrator state. Sized so `ki * integral` alone can
    /// span roughly the full output range (50 * 0.15 ≈ 7.5 at balanced
    /// preset — a modest steady-state offset correction).
    public var integralMin: Double = -50
    public var integralMax: Double = 50

    public init(kp: Double, ki: Double, setpoint: Double) {
        self.kp = kp
        self.ki = ki
        self.setpoint = setpoint
    }

    /// Advance the controller by one tick.
    ///
    /// - Parameters:
    ///   - measurement: latest sensor reading, same units as `setpoint`.
    ///   - dt: elapsed seconds since the previous tick.
    ///   - skipIntegralUpdate: when true, only the proportional term updates
    ///     for this tick. Caller uses this after a long sleep/wake gap to
    ///     avoid a huge accumulated error kick.
    /// - Returns: clamped output in `[outputMin, outputMax]`.
    public mutating func tick(measurement: Double, dt: Double, skipIntegralUpdate: Bool = false) -> Double {
        // Defense-in-depth: the caller should filter non-finite inputs, but
        // a stray NaN here would poison `integral` permanently. Return a
        // safe integral-only output, clamped, and leave state alone. The
        // upstream missing-sensor path covers the legitimate "no reading"
        // case via the nil-returning resolver.
        //
        // NaN-clamp correctness: Swift's `max(_:_:)` is defined as
        // `y < x ? x : y`. `0 < NaN` is false, so `max(NaN, outputMin)`
        // returns `outputMin`; the subsequent `min` then returns the
        // (finite) `outputMin`. If you ever refactor to `Double.maximum`
        // (IEEE-754 max, which prefers the non-NaN argument), behavior is
        // unchanged — but don't swap in something that propagates NaN.
        guard measurement.isFinite, dt.isFinite else {
            return min(max(-ki * integral, outputMin), outputMax)
        }
        let error = setpoint - measurement

        // Unclamped output using current integral state.
        let unclampedBefore = -kp * error - ki * integral

        if !skipIntegralUpdate && dt > 0 {
            // Conditional integration: integrate when the previous unclamped
            // output sat inside the saturation limits, OR when the new error
            // would walk the integrator back toward a non-saturated region.
            // Without this, windup during saturation adds phantom headroom
            // the controller has to unwind later.
            let withinLimits = unclampedBefore >= outputMin && unclampedBefore <= outputMax
            let goingBackInto = (unclampedBefore > outputMax && error > 0)
                || (unclampedBefore < outputMin && error < 0)
            if withinLimits || goingBackInto {
                integral += error * dt
                integral = min(max(integral, integralMin), integralMax)
            }
        }

        let unclamped = -kp * error - ki * integral
        return min(max(unclamped, outputMin), outputMax)
    }

    public mutating func reset() {
        integral = 0
    }
}
