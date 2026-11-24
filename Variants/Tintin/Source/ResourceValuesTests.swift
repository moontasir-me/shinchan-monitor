import Foundation
@main struct ResourceValuesTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool,_ message: String) { guard value() else { fatalError(message) }; checks += 1 }
        check(BatteryReading.percentage(current:40,maximum:80) == 50,"Capacity units are normalized")
        check(BatteryReading.percentage(current:0,maximum:100) == 0,"Empty battery")
        check(BatteryReading.percentage(current:105,maximum:100) == 100,"New battery health capped at 100")
        check(BatteryReading.percentage(current:nil,maximum:100) == nil,"Missing capacity")
        check(BatteryReading.percentage(current:20,maximum:0) == nil,"Invalid denominator")
        check(BatteryReading.percentage(current:20,maximum:-1) == nil,"Negative denominator")
        check(BatteryReading.percentage(current:-1,maximum:100) == nil,"Negative capacity")
        check(BatteryReading.percentage(current:.nan,maximum:100) == nil,"Non-finite capacity")
        check(BatteryReading.percentage(current:20,maximum:.infinity) == nil,"Non-finite maximum")
        let memory = MemoryReading.make(anonymousPages:100,purgeablePages:20,wiredPages:30,compressedPages:10,pageSize:4096,totalBytes:1_000_000,swapBytes:500)!
        check(memory.usedBytes == 120*4096,"RAM includes anonymous, wired, compressed minus purgeable")
        check(abs(memory.percent-49.152)<0.0001,"RAM percent")
        check(memory.swapBytes == 500,"Swap retained separately")
        check(MemoryReading.make(anonymousPages:0,purgeablePages:10,wiredPages:0,compressedPages:0,pageSize:4096,totalBytes:1_000_000,swapBytes:nil)?.usedBytes == 0,"Counter skew avoids underflow")
        check(MemoryReading.make(anonymousPages:1000,purgeablePages:0,wiredPages:1000,compressedPages:0,pageSize:16384,totalBytes:100,swapBytes:nil)?.usedBytes == 100,"RAM capped at physical capacity")
        check(MemoryReading.make(anonymousPages:1,purgeablePages:0,wiredPages:1,compressedPages:0,pageSize:0,totalBytes:100,swapBytes:nil) == nil,"Unavailable page size")
        check(MemoryReading.make(anonymousPages:1,purgeablePages:0,wiredPages:1,compressedPages:0,pageSize:4096,totalBytes:0,swapBytes:nil) == nil,"Unavailable physical RAM")
        check(PowerReading.watts(milliwatts:6512) == 6.512,"Power milliwatts converted to watts")
        check(PowerReading.watts(milliwatts:0) == 0,"Zero power remains valid")
        check(PowerReading.watts(milliwatts:-1) == nil,"Negative power unavailable")
        check(PowerReading.watts(milliwatts:.nan) == nil,"Invalid power unavailable")
        print("Passed \(checks) RAM/battery checks.")
    }
}
