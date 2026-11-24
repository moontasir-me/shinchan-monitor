import Foundation

struct MemoryReading {
    let usedBytes: Double
    let totalBytes: Double
    let swapBytes: Double?
    var percent: Double { usedBytes / totalBytes * 100 }
    static func make(anonymousPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64, compressedPages: UInt64, pageSize: UInt64, totalBytes: UInt64, swapBytes: Double?) -> MemoryReading? {
        guard pageSize > 0, totalBytes > 0 else { return nil }
        let anonymous = Double(anonymousPages > purgeablePages ? anonymousPages-purgeablePages : 0)
        let used = (anonymous + Double(wiredPages) + Double(compressedPages)) * Double(pageSize)
        return MemoryReading(usedBytes:min(Double(totalBytes),used),totalBytes:Double(totalBytes),swapBytes:swapBytes)
    }
}

struct BatteryReading {
    let percent: Double?
    let charging: Bool
    let pluggedIn: Bool
    let healthPercent: Double?
    let condition: String?
    let cycles: Int?
    static func percentage(current: Double?, maximum: Double?) -> Double? {
        guard let current, let maximum, current.isFinite, maximum.isFinite, current >= 0, maximum > 0 else { return nil }
        return min(100,max(0,current/maximum*100))
    }
}
