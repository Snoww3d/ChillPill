import Foundation
import os.log
import ChillPillShared

enum Fans {
    private static let log = OSLog(subsystem: "dev.chillpill", category: "Fans")

    private static let maxFans = 16

    static func count() -> Int {
        guard let raw = SMC.shared.readDouble("FNum"), raw.isFinite else { return 0 }
        let n = Int(raw.rounded())
        guard n >= 0 && n <= maxFans else { return 0 }
        return n
    }

    static func readAll() -> [FanDTO] {
        let n = count()
        guard n > 0 else { return [] }
        return (0..<n).map { read($0) }
    }

    static func read(_ index: Int) -> FanDTO {
        func d(_ key: String) -> Double? { SMC.shared.readDouble(key) }
        let i = index
        return FanDTO(
            index: i,
            actualRPM: d("F\(i)Ac") ?? 0,
            minRPM:    d("F\(i)Mn"),
            maxRPM:    d("F\(i)Mx"),
            targetRPM: d("F\(i)Tg"),
            mode:      safeInt(d("F\(i)Md"))
        )
    }

    private static func safeInt(_ value: Double?) -> Int? {
        guard let v = value, v.isFinite else { return nil }
        return Int(v)
    }

    // MARK: - Control

    @discardableResult
    static func setAuto(_ index: Int) -> Bool {
        guard isValidIndex(index) else { return false }
        return SMC.shared.write("F\(index)Md", bytes: [0])
    }

    @discardableResult
    static func setTarget(_ index: Int, rpm: Double) -> Bool {
        guard isValidIndex(index) else { return false }
        guard rpm.isFinite else { return false }

        let reading = read(index)
        let clamped: Double
        if let mn = reading.minRPM, let mx = reading.maxRPM, mx > mn {
            clamped = min(max(rpm, mn), mx)
        } else {
            dumpFanKeysOnce(trigger: "setTarget F\(index)")
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
                    "Fans: Tg write failed AND restore-to-auto failed for F%d — fan may be stuck in forced mode",
                    log: Self.log, type: .error, index
                )
            }
        }
        return modeOK && targetOK
    }

    static func restoreAllToAuto() {
        for i in 0..<count() {
            _ = setAuto(i)
        }
    }

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
                dumpFanKeysOnce(trigger: "setAllTargets F\(i)")
                allOK = false
                continue
            }
            let rpm = mn + (mx - mn) * clampedPct / 100.0
            if !setTarget(i, rpm: rpm) { allOK = false }
        }
        return allOK
    }

    private static func isValidIndex(_ index: Int) -> Bool {
        index >= 0 && index < count()
    }

    // MARK: - Diagnostics

    private static var didDumpFanKeys = false

    /// One-shot diagnostic that enumerates every SMC key starting with "F"
    /// and logs its type + size, plus raw bytes for each fan's Mn/Mx. Fires
    /// the first time `setTarget` or `setAllTargets` rejects a write because
    /// the fan's [Min, Max] range can't be read — gives a Mac model that
    /// doesn't expose `F{n}Mn` / `F{n}Mx` (e.g. issue #19, M5 Pro / Mac17,8)
    /// an actionable log dump instead of just "range unknown".
    private static func dumpFanKeysOnce(trigger: String) {
        guard !didDumpFanKeys else { return }
        didDumpFanKeys = true

        os_log(
            "Fans: range unknown on %{public}@ — dumping SMC fan keys for diagnosis",
            log: Self.log, type: .info, trigger
        )

        let all = SMC.shared.discoverAllKeys()
        let fanKeys = all.filter { $0.key.hasPrefix("F") }
            .sorted { $0.key < $1.key }
        os_log("Fans: discovered %d F* keys:", log: Self.log, type: .info, fanKeys.count)
        for k in fanKeys {
            os_log(
                "Fans:   %{public}@  size=%u  type=%{public}@",
                log: Self.log, type: .info,
                k.key, k.info.dataSize, k.info.dataType
            )
        }

        let n = count()
        os_log("Fans: FNum=%d — probing per-fan Mn/Mx raw bytes:", log: Self.log, type: .info, n)
        for i in 0..<n {
            for suffix in ["Mn", "Mx", "Ac", "Tg", "Md", "Sf"] {
                let key = "F\(i)\(suffix)"
                if let v = SMC.shared.read(key) {
                    let hex = v.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                    let decoded = SMC.shared.readDouble(key).map { String(format: "%.2f", $0) } ?? "nil"
                    os_log(
                        "Fans:   %{public}@  type=%{public}@  bytes=[%{public}@]  decoded=%{public}@",
                        log: Self.log, type: .info,
                        key, v.info.dataType, hex, decoded
                    )
                } else {
                    os_log("Fans:   %{public}@  ABSENT", log: Self.log, type: .info, key)
                }
            }
        }
    }
}
