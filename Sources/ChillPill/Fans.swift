import Foundation

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
    static func count() -> Int {
        Int(SMC.shared.readDouble("FNum") ?? 0)
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
            mode:      d("F\(i)Md").map(Int.init)
        )
    }

    // MARK: - Control

    /// Hand fan control back to the SMC's thermal policy (`F{n}Md = 0`).
    @discardableResult
    static func setAuto(_ index: Int) -> Bool {
        SMC.shared.write("F\(index)Md", bytes: [0])
    }

    /// Force a specific target RPM. Mode is flipped to "forced" (`F{n}Md = 1`)
    /// before the target is written. The caller is responsible for clamping
    /// `rpm` into the `[minRPM, maxRPM]` range from `read(_:)`.
    @discardableResult
    static func setTarget(_ index: Int, rpm: Double) -> Bool {
        let modeOK = SMC.shared.write("F\(index)Md", bytes: [1])
        let targetOK = SMC.shared.write(
            "F\(index)Tg",
            bytes: SMC.encodeFLT(Float(rpm))
        )
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
}
