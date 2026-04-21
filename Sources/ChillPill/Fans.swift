import Foundation
import os.log

struct FanReading {
    let index: Int
    let actualRPM: Double
    let minRPM: Double?
    let maxRPM: Double?
    let targetRPM: Double?
    /// 0 = auto, 1 = forced (if the key exists on this hardware).
    let mode: Int?
}

enum Fans {
    private static let log = OSLog(subsystem: "dev.chillpill", category: "Fans")

    /// Upper bound on fan count from SMC. Used to guard against a malformed
    /// FNum read (e.g. a future decoder bug emitting NaN/huge).
    private static let maxFans = 16

    static func count() -> Int {
        guard let raw = SMC.shared.readDouble("FNum"), raw.isFinite else { return 0 }
        let n = Int(raw.rounded())
        guard n >= 0 && n <= maxFans else { return 0 }
        return n
    }

    static func readAll() -> [FanReading] {
        let n = count()
        guard n > 0 else { return [] }
        return (0..<n).map { read($0) }
    }

    static func read(_ index: Int) -> FanReading {
        func d(_ key: String) -> Double? { SMC.shared.readDouble(key) }
        let i = index
        return FanReading(
            index: i,
            actualRPM: d("F\(i)Ac") ?? 0,
            minRPM:    d("F\(i)Mn"),
            maxRPM:    d("F\(i)Mx"),
            targetRPM: d("F\(i)Tg"),
            mode:      safeInt(d("F\(i)Md"))
        )
    }

    /// `Int(Double)` traps on NaN/Inf/out-of-range. Guard at every conversion
    /// site so a decoder bug in SMC.swift can't crash the app.
    private static func safeInt(_ value: Double?) -> Int? {
        guard let v = value, v.isFinite else { return nil }
        return Int(v)
    }

    // MARK: - Control

    /// Hand fan control back to the SMC's thermal policy (`F{n}Md = 0`).
    @discardableResult
    static func setAuto(_ index: Int) -> Bool {
        guard isValidIndex(index) else { return false }
        return SMC.shared.write("F\(index)Md", bytes: [0])
    }

    /// Force a specific target RPM. Validates index bounds, rejects
    /// non-finite values, and clamps `rpm` into the fan's advertised
    /// `[minRPM, maxRPM]` range before writing. If the target write fails
    /// *after* the mode flip, we restore auto mode so the fan isn't left in
    /// forced-mode with a stale target.
    @discardableResult
    static func setTarget(_ index: Int, rpm: Double) -> Bool {
        guard isValidIndex(index) else { return false }
        guard rpm.isFinite else { return false }

        let reading = read(index)
        let clamped: Double
        if let mn = reading.minRPM, let mx = reading.maxRPM, mx > mn {
            clamped = min(max(rpm, mn), mx)
        } else {
            // Without an advertised range we can't safely pick a target at
            // all — refuse rather than let the caller push an unknown value.
            return false
        }

        let modeOK = SMC.shared.write("F\(index)Md", bytes: [1])
        let targetOK = SMC.shared.write(
            "F\(index)Tg",
            bytes: SMC.encodeFLT(Float(clamped))
        )
        if modeOK && !targetOK {
            let restored = SMC.shared.write("F\(index)Md", bytes: [0])
            if !restored {
                os_log(
                    "Fans: Tg write failed AND restore-to-auto failed for F%d — fan may be stuck in forced mode until next boot or another setAuto attempt",
                    log: Self.log, type: .error, index
                )
            }
        }
        return modeOK && targetOK
    }

    /// Best-effort "restore everything to auto" — useful on app shutdown so we
    /// don't leave the system thermally mismanaged if the user quits without
    /// clicking Auto first.
    static func restoreAllToAuto() {
        for i in 0..<count() {
            _ = setAuto(i)
        }
    }

    /// Apply the same percentage (0-100) to every fan, scaled against each
    /// fan's *own* advertised [Min, Max] range. Fans whose range is unknown
    /// or degenerate are skipped; the return value reflects whether every
    /// fan accepted its write.
    @discardableResult
    static func setAllTargets(pct: Double) -> Bool {
        guard pct.isFinite else { return false }
        let clampedPct = min(max(pct, 0), 100)
        let n = count()
        guard n > 0 else { return false }
        var allOK = true
        for i in 0..<n {
            let reading = read(i)
            guard let mn = reading.minRPM, let mx = reading.maxRPM, mx > mn else {
                allOK = false
                continue
            }
            let rpm = mn + (mx - mn) * clampedPct / 100.0
            if !setTarget(i, rpm: rpm) { allOK = false }
        }
        return allOK
    }

    // MARK: - Helpers

    private static func isValidIndex(_ index: Int) -> Bool {
        index >= 0 && index < count()
    }
}
