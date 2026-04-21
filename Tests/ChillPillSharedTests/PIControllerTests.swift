import XCTest
import ChillPillShared

final class PIControllerTests: XCTestCase {

    // MARK: - Sign convention

    /// Measurement above setpoint should produce a LARGER fan percent than
    /// measurement at setpoint. This is the load-bearing convention —
    /// getting the sign wrong would drive fans the wrong direction.
    func testHotterThanSetpointProducesLargerOutput() {
        var pi = PIController(kp: 4.0, ki: 0.15, setpoint: 75.0)
        let atSetpoint = pi.tick(measurement: 75.0, dt: 2.0)
        pi.reset()
        let aboveSetpoint = pi.tick(measurement: 85.0, dt: 2.0)
        XCTAssertGreaterThan(aboveSetpoint, atSetpoint,
                             "hotter measurement should push fans harder")
    }

    /// Measurement below setpoint should produce output at or near
    /// `outputMin` — we don't cool below target.
    func testBelowSetpointClampsToMin() {
        var pi = PIController(kp: 4.0, ki: 0.15, setpoint: 75.0)
        let output = pi.tick(measurement: 50.0, dt: 2.0)
        XCTAssertEqual(output, pi.outputMin, accuracy: 0.001,
                       "cold measurement should saturate at outputMin")
    }

    // MARK: - First tick / skipIntegralUpdate

    /// `skipIntegralUpdate=true` must leave the integrator alone — used for
    /// the first tick and after sleep/wake gaps.
    func testSkipIntegralUpdateLeavesIntegralUnchanged() {
        var pi = PIController(kp: 4.0, ki: 0.15, setpoint: 75.0)
        let before = pi.integral
        _ = pi.tick(measurement: 85.0, dt: 2.0, skipIntegralUpdate: true)
        XCTAssertEqual(pi.integral, before, accuracy: 1e-12)
    }

    /// `dt <= 0` must not integrate — prevents div-by-zero / reverse time.
    func testNonPositiveDtLeavesIntegralUnchanged() {
        var pi = PIController(kp: 4.0, ki: 0.15, setpoint: 75.0)
        let before = pi.integral
        _ = pi.tick(measurement: 85.0, dt: 0.0)
        XCTAssertEqual(pi.integral, before)
        _ = pi.tick(measurement: 85.0, dt: -1.0)
        XCTAssertEqual(pi.integral, before)
    }

    // MARK: - Anti-windup

    /// Holding the output saturated for many ticks must not cause the
    /// integrator to grow beyond `integralMax` — conditional integration
    /// stops accumulating once the unclamped output is outside the output
    /// saturation limits and the error sign is not walking it back.
    func testIntegratorBoundedWhileOutputSaturated() {
        var pi = PIController(kp: 4.0, ki: 0.15, setpoint: 75.0)
        // Very hot for 60 ticks at 2s each → would integrate far past the
        // clamp without anti-windup.
        for _ in 0..<60 {
            _ = pi.tick(measurement: 95.0, dt: 2.0)
        }
        XCTAssertLessThanOrEqual(pi.integral, pi.integralMax,
                                 "integral must be bounded by integralMax")
        XCTAssertGreaterThanOrEqual(pi.integral, pi.integralMin,
                                    "integral must be bounded by integralMin")
    }

    /// After prolonged above-setpoint saturation, if the temperature drops
    /// back below setpoint, the controller should unwind the integrator
    /// (via conditional integration) and return to a low output within a
    /// reasonable number of ticks — NOT take minutes to recover.
    func testIntegratorUnwindsAfterSaturation() {
        var pi = PIController(kp: 4.0, ki: 0.15, setpoint: 75.0)
        // Drive saturation with 30 hot ticks.
        for _ in 0..<30 {
            _ = pi.tick(measurement: 95.0, dt: 2.0)
        }
        XCTAssertEqual(pi.tick(measurement: 95.0, dt: 2.0), pi.outputMax,
                       accuracy: 0.001, "should still be saturated at top")
        // Now simulate fast cooling. Output should unwind toward outputMin
        // within a small number of ticks.
        var out = pi.outputMax
        for _ in 0..<30 {
            out = pi.tick(measurement: 40.0, dt: 2.0)
        }
        XCTAssertEqual(out, pi.outputMin, accuracy: 0.001,
                       "should return to outputMin after cooling")
    }

    // MARK: - NaN / infinity defense

    func testNaNMeasurementDoesNotPoisonIntegrator() {
        var pi = PIController(kp: 4.0, ki: 0.15, setpoint: 75.0)
        let before = pi.integral
        _ = pi.tick(measurement: .nan, dt: 2.0)
        XCTAssertEqual(pi.integral, before, "NaN measurement must not mutate integral")
    }

    func testInfiniteMeasurementDoesNotPoisonIntegrator() {
        var pi = PIController(kp: 4.0, ki: 0.15, setpoint: 75.0)
        let before = pi.integral
        _ = pi.tick(measurement: .infinity, dt: 2.0)
        XCTAssertEqual(pi.integral, before)
    }

    func testNaNDtDoesNotPoisonIntegrator() {
        var pi = PIController(kp: 4.0, ki: 0.15, setpoint: 75.0)
        let before = pi.integral
        _ = pi.tick(measurement: 85.0, dt: .nan)
        XCTAssertEqual(pi.integral, before)
    }

    // MARK: - Reset

    func testResetZeroesIntegralButPreservesTuning() {
        var pi = PIController(kp: 4.0, ki: 0.15, setpoint: 75.0)
        for _ in 0..<20 { _ = pi.tick(measurement: 95.0, dt: 2.0) }
        XCTAssertNotEqual(pi.integral, 0)
        pi.reset()
        XCTAssertEqual(pi.integral, 0)
        XCTAssertEqual(pi.kp, 4.0)
        XCTAssertEqual(pi.ki, 0.15)
        XCTAssertEqual(pi.setpoint, 75.0)
    }
}
