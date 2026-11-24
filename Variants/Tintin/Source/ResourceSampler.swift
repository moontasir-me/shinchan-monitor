import Foundation
import Darwin
import IOKit
import IOKit.ps

// Local kernel/power-source reads only. No shell subprocesses or network calls.
final class ResourceSampler {
    func memory() -> MemoryReading? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_,host) }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size/MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { host_statistics64(host,HOST_VM_INFO64,$0,&count) }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host,&pageSize) == KERN_SUCCESS else { return nil }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage",&swap,&size,nil,0) == 0
        return MemoryReading.make(anonymousPages:UInt64(info.internal_page_count),purgeablePages:UInt64(info.purgeable_count),wiredPages:UInt64(info.wire_count),compressedPages:UInt64(info.compressor_page_count),pageSize:UInt64(pageSize),totalBytes:ProcessInfo.processInfo.physicalMemory,swapBytes:hasSwap ? Double(swap.xsu_used) : nil)
    }
    func battery() -> BatteryReading? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(snapshot,source)?.takeUnretainedValue() as? [String:Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            func number(_ key: String) -> Double? { (d[key] as? NSNumber)?.doubleValue }
            let charge = BatteryReading.percentage(current:number(kIOPSCurrentCapacityKey),maximum:number(kIOPSMaxCapacityKey))
            var condition = d[kIOPSBatteryHealthConditionKey] as? String
            if condition?.isEmpty != false { condition = d[kIOPSBatteryHealthKey] as? String }
            var health: Double?
            var cycles: Int?
            let service = IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func property(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(service,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue()
                }
                cycles = (property("CycleCount") as? NSNumber)?.intValue
                // Read only capacity values from this dictionary. Never log identifiers or raw battery dictionaries.
                let capacity = property("BatteryData") as? [String:Any]
                let design = (property("DesignCapacity") as? NSNumber)?.doubleValue ?? (capacity?["DesignCapacity"] as? NSNumber)?.doubleValue
                let nominal = (property("NominalChargeCapacity") as? NSNumber)?.doubleValue ?? (capacity?["NominalChargeCapacity"] as? NSNumber)?.doubleValue
                let raw = (property("AppleRawMaxCapacity") as? NSNumber)?.doubleValue ?? (capacity?["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue
                health = BatteryReading.percentage(current:nominal ?? raw,maximum:design)
            }
            return BatteryReading(percent:charge,charging:d[kIOPSIsChargingKey] as? Bool ?? false,pluggedIn:d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,healthPercent:health,condition:condition,cycles:cycles)
        }
        return nil
    }
}
