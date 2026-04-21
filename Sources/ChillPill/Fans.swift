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
}
