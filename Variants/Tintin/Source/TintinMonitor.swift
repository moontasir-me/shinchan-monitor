import AppKit
import Darwin
import IOKit
import Metal
import ServiceManagement

struct Reading {
    let cpu: Double?
    let gpu: Double?
    let date: Date
    var cpuTemperature: Double? = nil
    var gpuTemperature: Double? = nil
    var topCPU: [AppUsage] = []
    var topGPU: [AppUsage] = []
    var topEnergy: [AppUsage] = []
    var processCount = 0
    var diskRate = 0.0
    var memory: MemoryReading? = nil
    var battery: BatteryReading? = nil
}

struct AppUsage {
    let name: String
    let value: Double
}

final class DetailSampler {
    private var previous: [Int32: SMProcessSample] = [:]
    private var names: [Int32: (UInt64, String)] = [:]
    private var gpuPrevious: [UInt64: (Int32, UInt64)] = [:]
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private let connection = sm_smc_open()
    private var tickNS = 1.0
    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        tickNS = Double(info.numer) / Double(info.denom)
    }
    deinit { sm_smc_close(connection) }
    private func name(_ pid: Int32, _ birth: UInt64) -> String {
        if let cached = names[pid], cached.0 == birth { return cached.1 }
        var buffer = [CChar](repeating: 0, count: 4096)
        let result: String
        if sm_process_path(pid, &buffer, Int32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if let end = path.range(of: ".app/") {
                result = URL(fileURLWithPath: String(path[..<end.lowerBound]) + ".app").deletingPathExtension().lastPathComponent
            } else { result = URL(fileURLWithPath: path).lastPathComponent }
        } else {
            _ = sm_process_name(pid, &buffer, Int32(buffer.count))
            result = buffer[0] == 0 ? "Process \(pid)" : String(cString: buffer)
        }
        names[pid] = (birth, result)
        return result
    }
    private func gpuCounters() -> [UInt64: (Int32, UInt64)] {
        var roots: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOGPU"), &roots) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(roots) }
        var counters: [UInt64: (Int32, UInt64)] = [:]
        while case let root = IOIteratorNext(roots), root != 0 {
            defer { IOObjectRelease(root) }
            var children: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let entry = IOIteratorNext(children), entry != 0 {
                defer { IOObjectRelease(entry) }
                guard let usage = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]],
                      let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                      let pidString = creator.split(separator: ",").first?.split(separator: " ").last,
                      let pid = Int32(pidString) else { continue }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { continue }
                let total = usage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                counters[id] = (pid, total)
            }
        }
        return counters
    }
    private func temperature(_ keys: [String]) -> Double? {
        let values = keys.map { sm_smc_temperature(connection, $0) }.filter { $0.isFinite }
        return values.isEmpty ? nil : values.reduce(0,+) / Double(values.count)
    }
    func enrich(_ reading: Reading) -> Reading {
        var r = reading
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTime
        let validInterval = elapsed > 0.2 && elapsed < 15
        var pids = [Int32](repeating: 0, count: 32768)
        let count = max(0, min(pids.count, Int(sm_list_pids(&pids, Int32(pids.count)))))
        var next: [Int32: SMProcessSample] = [:]
        var cpu: [String: Double] = [:]
        var energy: [String: Double] = [:]
        var disk = 0.0
        for pid in pids.prefix(count) where pid > 0 {
            var sample = SMProcessSample()
            guard sm_process_sample(pid, &sample) else { continue }
            next[pid] = sample
            let title = name(pid, sample.startedTicks)
            guard validInterval, let old = previous[pid], old.startedTicks == sample.startedTicks else { continue }
            if sample.cpuTicks >= old.cpuTicks {
                cpu[title, default: 0] += Double(sample.cpuTicks-old.cpuTicks)*tickNS/1e9/elapsed*100/Double(ProcessInfo.processInfo.activeProcessorCount)
            }
            if sample.energyAvailable && old.energyAvailable && sample.energyNanojoules >= old.energyNanojoules {
                energy[title,default:0] += Double(sample.energyNanojoules-old.energyNanojoules)/1e9/elapsed
            }
            if sample.bytesRead >= old.bytesRead && sample.bytesWritten >= old.bytesWritten {
                disk += Double(sample.bytesRead-old.bytesRead) + Double(sample.bytesWritten-old.bytesWritten)
            }
        }
        let gpuNext = gpuCounters()
        var gpu: [String: Double] = [:]
        if validInterval {
            for (id, item) in gpuNext {
                guard let old = gpuPrevious[id], old.0 == item.0, item.1 >= old.1 else { continue }
                let birth = next[item.0]?.startedTicks ?? 0
                gpu[name(item.0, birth), default: 0] += Double(item.1-old.1)/1e6/elapsed
            }
        }
        func top(_ values: [String: Double]) -> [AppUsage] {
            values.filter { $0.value > 0.01 }.sorted { $0.value > $1.value }.prefix(2).map { AppUsage(name: $0.key, value: $0.value) }
        }
        r.topCPU = top(cpu); r.topGPU = top(gpu); r.topEnergy = top(energy)
        r.processCount = count; r.diskRate = validInterval ? disk/elapsed : 0
        r.cpuTemperature = temperature(["Te05","Te0S","Te09","Te0H","Tp01","Tp05","Tp09","Tp0D","Tp0V","Tp0Y","Tp0b","Tp0e"])
        r.gpuTemperature = temperature(["Tg0G","Tg0H","Tg0K","Tg0L","Tg0d","Tg0e","Tg0j","Tg0k"])
        previous = next; gpuPrevious = gpuNext; lastTime = now
        names = names.filter { next[$0.key] != nil }
        return r
    }
}

final class SystemSampler {
    private let details = DetailSampler()
    private let resources = ResourceSampler()
    private let host = mach_host_self()
    private var previous: [UInt32]?
    private var accelerators: [io_service_t] = []
    let cpuName: String
    let gpuName: String

    init() {
        var length = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &length, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, length))
        if length > 0 { _ = sysctlbyname("machdep.cpu.brand_string", &bytes, &length, nil, 0) }
        cpuName = bytes.first == 0 ? "CPU" : String(cString: bytes)
        gpuName = MTLCreateSystemDefaultDevice()?.name ?? "GPU"
        discoverGPUs()
        _ = readCPU()
    }

    deinit {
        accelerators.forEach { IOObjectRelease($0) }
        mach_port_deallocate(mach_task_self_, host)
    }

    private func discoverGPUs() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            accelerators.append(entry)
        }
    }

    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { previous = ticks }
        guard let old = previous else { return nil }
        let deltas = zip(ticks, old).map { UInt64($0 &- $1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        return min(100, max(0, 100 * Double(total - deltas[Int(CPU_STATE_IDLE)]) / Double(total)))
    }

    private func readGPU() -> Double? {
        var values: [Double] = []
        for entry in accelerators {
            guard let value = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = value as? [String: Any] else { continue }
            for key in ["Device Utilization %", "GPU Activity(%)", "GPU Utilization %"] {
                if let number = stats[key] as? NSNumber, number.doubleValue.isFinite {
                    values.append(min(100, max(0, number.doubleValue)))
                    break
                }
            }
        }
        // If multiple GPUs are present, show the busiest accelerator.
        return values.max()
    }

    func sample() -> Reading {
        var reading = details.enrich(Reading(cpu:readCPU(),gpu:readGPU(),date:Date()))
        reading.memory = resources.memory(); reading.battery = resources.battery()
        return reading
    }
}

final class Sparkline: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var tint = NSColor.systemBlue
    override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1 else { return }
        let rect = bounds.insetBy(dx: 1, dy: 3)
        let line = NSBezierPath()
        for (i, value) in values.enumerated() {
            let point = NSPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1), y: rect.minY + rect.height * CGFloat(min(100, max(0, value))) / 100)
            if i == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        fill.line(to: NSPoint(x: rect.minX, y: rect.minY)); fill.close()
        tint.withAlphaComponent(0.12).setFill(); fill.fill()
        tint.setStroke(); line.lineWidth = 2; line.lineJoinStyle = .round; line.stroke()
    }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

final class MetricCard: NSView {
    private let valueLabel = label("—", size: 30, weight: .semibold)
    private let detailLabel: NSTextField
    private let graph = Sparkline()
    private let meter = NSProgressIndicator()
    private var history: [Double] = []

    init(title: String, detail: String, symbol: String, tint: NSColor) {
        detailLabel = label(detail, size: 11, color: .secondaryLabelColor)
        super.init(frame: NSRect(x: 0, y: 0, width: 312, height: 103))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        layer?.cornerRadius = 15
        let image = NSImageView(frame: NSRect(x: 14, y: 73, width: 16, height: 16))
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        image.contentTintColor = tint
        addSubview(image)
        let heading = label(title, size: 12, weight: .semibold)
        heading.frame = NSRect(x: 36, y: 71, width: 130, height: 20); addSubview(heading)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        valueLabel.frame = NSRect(x: 14, y: 33, width: 130, height: 37); addSubview(valueLabel)
        detailLabel.frame = NSRect(x: 14, y: 15, width: 270, height: 16); addSubview(detailLabel)
        graph.tint = tint; graph.frame = NSRect(x: 147, y: 39, width: 149, height: 43); addSubview(graph)
        meter.style = .bar; meter.isIndeterminate = false; meter.minValue = 0; meter.maxValue = 100
        meter.controlSize = .small; meter.frame = NSRect(x: 15, y: 5, width: 281, height: 5)
        addSubview(meter)
        setAccessibilityElement(true); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ value: Double?) {
        if let value {
            valueLabel.stringValue = String(format: "%.0f%%", value)
            meter.doubleValue = value
            history.append(value); history = Array(history.suffix(30)); graph.values = history
            setAccessibilityValue(valueLabel.stringValue)
        } else {
            valueLabel.stringValue = "—"; meter.doubleValue = 0
            setAccessibilityValue("Data unavailable")
        }
    }
}

func loginStatus() -> String {
    switch SMAppService.mainApp.status {
    case .enabled: return "On"
    case .requiresApproval: return "Approval needed in Login Items"
    case .notRegistered: return "Off"
    case .notFound: return "App unavailable"
    @unknown default: return "Unknown"
    }
}

final class CompactMetric: NSView {
    private let value = label("—",size:23,weight:.semibold)
    private let graph = Sparkline()
    private var history: [Double] = []
    init(_ title:String,_ tint:NSColor) {
        super.init(frame:NSRect(x:0,y:0,width:148,height:70))
        wantsLayer = true; layer?.cornerRadius = 12; layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        let heading = label(title,size:11,weight:.semibold,color:tint); heading.frame = NSRect(x:10,y:46,width:128,height:17); addSubview(heading)
        value.frame = NSRect(x:10,y:16,width:128,height:30); addSubview(value)
        graph.tint = tint; graph.frame = NSRect(x:9,y:3,width:130,height:14); addSubview(graph)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ reading:Double?) {
        value.stringValue = reading.map { String(format:"%.0f%%",$0) } ?? "—"
        if let reading { history.append(reading); history = Array(history.suffix(30)); graph.values = history }
    }
}

final class StatsController: NSViewController {
    let cpuCard = CompactMetric("CPU",.systemCyan)
    let gpuCard = CompactMetric("GPU",.systemOrange)
    private let temperatures = label("",size:12,weight:.medium)
    private let cpuApps = label("",size:10,color:.secondaryLabelColor)
    private let gpuApps = label("",size:10,color:.secondaryLabelColor)
    private let ram = label("",size:12,weight:.semibold)
    private let battery = label("",size:12,weight:.semibold)
    private let health = label("",size:11,color:.secondaryLabelColor)
    private let activity = label("",size:11,color:.secondaryLabelColor)
    private let sizeLabel = label("Pet size",size:12)
    private let slider = NSSlider(value:100,minValue:50,maxValue:200,target:nil,action:nil)
    private let login = NSButton(checkboxWithTitle:"Start automatically at login",target:nil,action:nil)
    private let loginDetail = label("",size:11,color:.secondaryLabelColor)
    private let tabs = NSSegmentedControl(labels:["Overview","Power","Settings"],trackingMode:.selectOne,target:nil,action:nil)
    private var pages: [NSView] = []
    private let powerBattery = label("",size:13,weight:.semibold)
    private let powerTemperature = label("",size:13)
    private let systemPower = label("",size:13,weight:.semibold)
    private let adapterPower = label("",size:13,weight:.semibold)
    private let adapterMaximum = label("",size:11,color:.secondaryLabelColor)
    private let powerHealth = label("",size:11,color:.secondaryLabelColor)
    private let energyApps = label("",size:11,color:.secondaryLabelColor)
    private let batteryGraph = Sparkline()
    private let systemGraph = Sparkline()
    private var batteryHistory: [Double] = []
    private var powerHistory: [Double] = []
    var onClose: (() -> Void)?
    var onSize: ((Double) -> Void)?
    var onAlerts: (() -> Void)?
    init(cpuName:String,gpuName:String) { super.init(nibName:nil,bundle:nil) }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let root = NSVisualEffectView(frame:NSRect(x:0,y:0,width:336,height:450))
        root.material = .popover; root.state = .active; root.blendingMode = .behindWindow
        root.appearance = NSAppearance(named:.darkAqua); view = root
        func place(_ v:NSView,_ parent:NSView,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat) { v.frame = NSRect(x:x,y:y,width:w,height:h); parent.addSubview(v) }
        place(label("Tintin",size:19,weight:.bold),root,16,407,150,27)
        place(label("Local only · network blocked",size:10,color:.secondaryLabelColor),root,16,389,230,16)
        let alerts = NSButton(title:"Alerts…",target:self,action:#selector(openAlerts)); alerts.bezelStyle = .rounded; place(alerts,root,213,407,80,25)
        let close = NSButton(image:NSImage(systemSymbolName:"xmark.circle.fill",accessibilityDescription:"Close statistics")!,target:self,action:#selector(closePanel)); close.isBordered = false; place(close,root,301,409,22,22)
        tabs.target = self; tabs.action = #selector(changeTab); tabs.selectedSegment = 0; place(tabs,root,14,356,308,27)
        for _ in 0..<3 { let page = NSView(frame:NSRect(x:12,y:10,width:312,height:336)); root.addSubview(page); pages.append(page) }
        let overview = pages[0], power = pages[1], settings = pages[2]
        place(cpuCard,overview,0,263,148,70); place(gpuCard,overview,164,263,148,70)
        place(cpuApps,overview,4,218,144,39); cpuApps.maximumNumberOfLines = 2
        place(gpuApps,overview,168,218,144,39); gpuApps.maximumNumberOfLines = 2
        cpuApps.toolTip = "Top two CPU apps, grouped with helpers. Percent of total machine CPU capacity."
        gpuApps.toolTip = "Top two GPU apps by GPU time in milliseconds per second."
        place(temperatures,overview,4,185,304,23)
        place(ram,overview,4,155,304,23); place(battery,overview,4,124,304,23); place(health,overview,4,99,304,22)
        health.toolTip = "Estimated remaining full-charge capacity versus design capacity; capped at 100%."
        place(activity,overview,4,14,304,76); activity.maximumNumberOfLines = 4; activity.lineBreakMode = .byWordWrapping
        place(powerBattery,power,4,302,304,24)
        batteryGraph.tint = .systemGreen; place(batteryGraph,power,4,267,304,30)
        place(label("APPS USING ENERGY",size:10,weight:.semibold,color:.secondaryLabelColor),power,4,242,304,18)
        place(energyApps,power,4,201,304,39); energyApps.maximumNumberOfLines = 2
        energyApps.toolTip = "Top two apps by kernel-reported process energy delta per second, in watts. Not a full system energy attribution."
        place(powerTemperature,power,4,168,304,24)
        place(systemPower,power,4,135,304,24)
        systemGraph.tint = .systemOrange; place(systemGraph,power,4,101,304,29)
        systemPower.toolTip = "System power reported by SMC, or the local battery power telemetry fallback."
        place(adapterPower,power,4,69,304,24); place(adapterMaximum,power,4,46,304,20)
        adapterPower.toolTip = "Measured adapter input; adapter maximum is its reported rated capacity, not present usage."
        place(powerHealth,power,4,12,304,25)
        place(sizeLabel,settings,4,290,304,24)
        slider.target = self; slider.action = #selector(changeSize); slider.isContinuous = true; slider.setAccessibilityLabel("Pet size percent"); place(slider,settings,0,259,310,27)
        login.target = self; login.action = #selector(changeLogin); place(login,settings,0,211,312,25); place(loginDetail,settings,4,186,304,20)
        let monitor = NSButton(title:"Activity Monitor",target:self,action:#selector(openMonitor)); monitor.bezelStyle = .rounded; place(monitor,settings,0,131,312,30)
        let downloads = NSButton(title:"Downloads",target:self,action:#selector(openDownloads)); downloads.bezelStyle = .rounded; place(downloads,settings,0,91,312,30)
        let local = label("Hardware readings and alerts run locally.\nThe pet's network access is blocked.",size:11,color:.secondaryLabelColor); local.maximumNumberOfLines = 2; place(local,settings,4,36,304,39)
        preferredContentSize = root.frame.size; setScale(UserDefaults.standard.double(forKey:"petScale")); refreshLogin(); changeTab()
    }
    @objc private func changeTab() { for (i,page) in pages.enumerated() { page.isHidden = i != tabs.selectedSegment } }
    @objc private func closePanel() { onClose?() }
    @objc private func openAlerts() { onAlerts?() }
    @objc private func changeSize() { setScale(slider.doubleValue/100); onSize?(slider.doubleValue/100) }
    func setScale(_ value:Double) { let scale = value == 0 ? 1 : value; slider.doubleValue = scale*100; sizeLabel.stringValue = "Pet size · \(Int(scale*100))%" }
    func refreshLogin() { login.state = SMAppService.mainApp.status == .enabled ? .on : .off; loginDetail.stringValue = "Login launch: " + loginStatus() }
    @objc private func changeLogin() {
        do { if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; refreshLogin() }
        catch { refreshLogin(); loginDetail.stringValue = error.localizedDescription }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    @objc private func openMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Utilities/Activity Monitor.app")) }
    @objc private func openDownloads() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) }
    func update(_ r: Reading) {
        _ = view
        cpuCard.update(r.cpu); gpuCard.update(r.gpu)
        if let m = r.memory {
            ram.stringValue = String(format:"RAM  %.1f / %.0f GiB · %.0f%%",m.usedBytes/1_073_741_824,m.totalBytes/1_073_741_824,m.percent)
            ram.toolTip = "Resident anonymous RAM minus purgeable pages, plus wired and compressed RAM; excludes reclaimable file cache." + (m.swapBytes.map { String(format:" Swap used: %.1f GiB.",$0/1_073_741_824) } ?? "")
        } else { ram.stringValue = "RAM · Unavailable" }
        if let b = r.battery {
            let percentage = b.percent.map { String(format:"%.0f%%",$0) } ?? "—"
            battery.stringValue = "Battery  \(percentage) · " + (b.charging ? "Charging" : b.pluggedIn ? "Plugged in" : "On battery")
            let capacity = b.healthPercent.map { String(format:"%.0f%% est.",$0) } ?? "Capacity unavailable"
            var parts = ["Health " + capacity]
            if let condition = b.condition, !condition.isEmpty { parts.append(condition) }
            if let cycles = b.cycles { parts.append("\(cycles) cycles") }
            health.stringValue = parts.joined(separator:" · ")
        } else { battery.stringValue = "Battery · Not available"; health.stringValue = "Battery health · Not available" }
        func temp(_ t: Double?) -> String { t.map { String(format:"%.0f",$0) } ?? "—" }
        temperatures.stringValue = "CPU \(temp(r.cpuTemperature)) °C      GPU \(temp(r.gpuTemperature)) °C"
        func rows(_ apps: [AppUsage], gpu: Bool) -> String {
            if apps.isEmpty { return gpu ? "No GPU activity reported yet" : "Sampling active apps…" }
            return apps.map { "\($0.name)  " + String(format:gpu ? "%.1f ms/s" : "%.1f%%",$0.value) }.joined(separator:"\n")
        }
        cpuApps.stringValue = rows(r.topCPU,gpu:false); gpuApps.stringValue = rows(r.topGPU,gpu:true)
        let busy = max(r.cpu ?? 0,r.gpu ?? 0)
        let state = busy > 70 ? "Busy" : busy > 25 ? "Working" : "Light activity"
        let names = Set((r.topCPU+r.topGPU).prefix(4).map { $0.name }).sorted().joined(separator:", ")
        let pressure: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: pressure = "Normal thermal pressure"
        case .fair: pressure = "Warm · moderate thermal pressure"
        case .serious: pressure = "High thermal pressure"
        case .critical: pressure = "Critical thermal pressure"
        @unknown default: pressure = "Thermal pressure unavailable"
        }
        activity.stringValue = "\(state) · \(r.processCount) processes\n\(names.isEmpty ? "Waiting for activity samples" : names)\nDisk I/O \(String(format:"%.1f",r.diskRate/1e6)) MB/s · \(pressure)"
        activity.toolTip = "Live sampled activity, not task progress. Process disk I/O includes reads and writes. Updates every two seconds."
        powerBattery.stringValue = battery.stringValue
        powerHealth.stringValue = health.stringValue
        func watts(_ value:Double?) -> String { value.map { String(format:"%.1f W",$0) } ?? "—" }
        powerTemperature.stringValue = "Battery temperature   " + (r.battery?.power?.batteryTemperature.map { String(format:"%.0f °C",$0) } ?? "—")
        systemPower.stringValue = "System   " + watts(r.battery?.power?.systemWatts)
        adapterPower.stringValue = "Adapter   " + (r.battery?.pluggedIn == true ? watts(r.battery?.power?.adapterWatts) : "Not connected")
        adapterMaximum.stringValue = r.battery?.power?.adapterMaximumWatts.map { String(format:"%.0f W rated maximum",$0) } ?? "Rated maximum unavailable"
        energyApps.stringValue = r.topEnergy.isEmpty ? "No per-app energy data reported" : r.topEnergy.map { "\($0.name)  " + watts($0.value) }.joined(separator:"\n")
        if let value = r.battery?.percent { batteryHistory.append(value); batteryHistory = Array(batteryHistory.suffix(30)); batteryGraph.values = batteryHistory }
        if let value = r.battery?.power?.systemWatts { powerHistory.append(value); powerHistory = Array(powerHistory.suffix(30)); let scale = max(10,powerHistory.max() ?? 10); systemGraph.values = powerHistory.map { $0/scale*100 } }
    }
}

final class PetView: NSView {
    private let atlas: NSImage
    private var images: [String: [NSImage]] = [:]
    private let durations: [String: [Double]] = [
        "idle": [0.55,0.55,0.12,0.55],
        "waving": [0.14,0.14,0.14,0.28],
        "running": [0.15,0.15,0.15,0.15],
        "alert": [0.25,0.25,0.25,0.25]
    ]
    private var timer: Timer?
    private var state = "idle"
    private var index = 0
    private var nextFrame = Date.timeIntervalSinceReferenceDate
    private var waveUntil: Double = 0
    private var tracking: NSTrackingArea?
    private var downEvent: NSEvent?
    private var downPoint: NSPoint = .zero
    private var didDrag = false
    var hardwareWarning = false
    var showsStatistics = false
    var onClick: (() -> Void)?
    var onMove: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    init(atlasURL: URL) throws {
        guard let loaded = NSImage(contentsOf: atlasURL), let bitmap = NSBitmapImageRep(data: try Data(contentsOf: atlasURL)), bitmap.pixelsWide == bitmap.pixelsHigh, bitmap.pixelsWide >= 1024 else {
            throw NSError(domain: "TintinMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "The pet sprite sheet is missing or has the wrong dimensions."])
        }
        atlas = loaded
        super.init(frame: NSRect(x: 0, y: 0, width: 192, height: 208))
        let cell = CGFloat(bitmap.pixelsWide)/4
        for (name, row, count) in [("idle",0,4),("running",1,4),("waving",2,4),("alert",3,4)] {
            images[name] = (0..<count).map { col in
                let frame = NSImage(size: NSSize(width: 192, height: 208))
                frame.lockFocus()
                atlas.draw(in: NSRect(x: 0,y: 8,width: 192,height: 192), from: NSRect(x: CGFloat(col)*cell,y: CGFloat(bitmap.pixelsHigh)-CGFloat(row+1)*cell,width: cell,height: cell), operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.none])
                frame.unlockFocus(); return frame
            }
        }
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("Tintin. Click for CPU and GPU usage. Drag to move. Right-click for options.")
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited,.activeAlways,.inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { waveUntil = Date.timeIntervalSinceReferenceDate + 0.7 }
    override func mouseDown(with event: NSEvent) {
        downEvent = event; downPoint = NSEvent.mouseLocation; didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let downEvent else { return }
        let p = NSEvent.mouseLocation
        if hypot(p.x-downPoint.x,p.y-downPoint.y) > 3 {
            didDrag = true; window?.performDrag(with: downEvent); onMove?()
        }
    }
    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick?() }
        downEvent = nil
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
    private func tick() {
        let now = Date.timeIntervalSinceReferenceDate
        let desired = hardwareWarning ? "alert" : (showsStatistics ? "running" : (now < waveUntil ? "waving" : "idle"))
        let lookIndex: Int? = nil
        if let lookIndex {
            if desired != state || index != lookIndex { state = desired; index = lookIndex; needsDisplay = true }
        } else if desired != state {
            state = desired; index = 0; nextFrame = now + (durations[state]?.first ?? 0.2); needsDisplay = true
        } else if now >= nextFrame, let ds = durations[state] {
            index = (index+1) % ds.count; nextFrame = now + ds[index]; needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let frames = images[state], frames.indices.contains(index) else { return }
        frames[index].draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.none])
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var panel: PetPanel!
    private var pet: PetView!
    private var statusItem: NSStatusItem!
    private let sampler = SystemSampler()
    private let alerts = HardwareAlertController()
    private var stats: StatsController!
    private let popover = NSPopover()
    private var sampleTimer: DispatchSourceTimer?
    private var latest: Reading?
    private let sampleQueue = DispatchQueue(label: "local.tintin.monitor.sampling", qos: .utility)
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !defaults.bool(forKey:"migratedLocalPreferences") {
            if let old = defaults.persistentDomain(forName:"local.shinchan.monitor") {
                for key in ["petScale","petX","petY","alertsEnabled","alertSound","alertCPUUsage","alertGPUUsage","alertCPUTemperature","alertGPUTemperature"] {
                    if defaults.object(forKey:key) == nil, let value = old[key] { defaults.set(value,forKey:key) }
                }
            }
            defaults.set(true,forKey:"migratedLocalPreferences")
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.tintin.monitor").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }
        guard let sprite = Bundle.main.url(forResource: "spritesheet",withExtension: "png") else { fail("The pet artwork is missing."); return }
        do { pet = try PetView(atlasURL: sprite) } catch { fail(error.localizedDescription); return }
        panel = PetPanel(contentRect: NSRect(x: 0,y: 0,width: 192,height: 208), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Tintin Desktop Pet"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.contentView = pet
        pet.onClick = { [weak self] in self?.toggleStats() }
        pet.onMove = { [weak self] in self?.popover.performClose(nil); self?.savePosition() }
        pet.onMenu = { [weak self] event in
            guard let self else { return }; NSMenu.popUpContextMenu(self.menu(), with: event, for: self.pet)
        }
        stats = StatsController(cpuName: sampler.cpuName, gpuName: sampler.gpuName)
        stats.onClose = { [weak self] in self?.popover.performClose(nil) }
        stats.onAlerts = { [weak self] in self?.popover.performClose(nil); self?.alerts.showSettings() }
        alerts.petFrame = { [weak self] in self?.panel.frame ?? .zero }
        alerts.onOpenStats = { [weak self] in
            guard let self else { return }; self.panel.orderFrontRegardless()
            if !self.popover.isShown { self.toggleStats() }
        }
        alerts.onState = { [weak self] active in
            self?.pet?.hardwareWarning = active
            self?.statusItem?.button?.title = active ? "⚠️" : "🐾"
            self?.statusItem?.button?.toolTip = active ? "Tintin · High hardware usage or temperature" : "Tintin · CPU and GPU usage"
        }
        stats.onSize = { [weak self] scale in self?.setSize(scale); self?.savePosition() }
        popover.contentViewController = stats; popover.behavior = .transient; popover.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"; statusItem.button?.toolTip = "Tintin · CPU and GPU usage"
        statusItem.menu = menu()
        setSize(defaults.double(forKey: "petScale") == 0 ? 1 : defaults.double(forKey: "petScale"))
        restorePosition(); panel.orderFrontRegardless()
        alerts.save(AlertPreferences(defaults:defaults))
        alerts.start()
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }; let reading = self.sampler.sample()
            DispatchQueue.main.async { [weak self] in self?.latest = reading; self?.stats.update(reading); self?.alerts.process(reading) }
        }
        sampleTimer = timer; timer.resume()
    }
    func applicationWillTerminate(_ notification: Notification) { sampleTimer?.cancel(); savePosition() }
    private func fail(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Tintin couldn’t start"; alert.informativeText = message; alert.runModal(); NSApp.terminate(nil)
    }
    @objc private func toggleStats() {
        if popover.isShown { popover.performClose(nil); return }
        stats.refreshLogin()
        if let latest { stats.update(latest) }
        pet.showsStatistics = true
        popover.show(relativeTo: NSRect(x: pet.bounds.midX-15,y: pet.bounds.maxY-45,width: 30,height: 12),of: pet,preferredEdge: .maxY)
    }
    func popoverDidClose(_ notification: Notification) { pet.showsStatistics = false }
    @objc private func showAlerts() { popover.performClose(nil); alerts.showSettings() }
    @objc private func showPet() { panel.orderFrontRegardless() }
    @objc private func resetPosition() {
        defaults.removeObject(forKey: "petX"); defaults.removeObject(forKey: "petY"); restorePosition(); panel.orderFrontRegardless()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func resizePet(_ sender: NSMenuItem) { setSize(Double(sender.tag)/100); savePosition() }
    private func setSize(_ scale: Double) {
        let value = min(2,max(0.5,scale)); defaults.set(value,forKey: "petScale")
        panel.setContentSize(NSSize(width: 192*value,height: 208*value))
        pet.frame = NSRect(origin: .zero,size: panel.frame.size)
        stats?.setScale(value)
    }
    private func menu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector) {
            let item = NSMenuItem(title: title,action: selector,keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        add("Show CPU & GPU usage",#selector(toggleStats)); add("Hardware alerts…",#selector(showAlerts)); add("Show Tintin",#selector(showPet))
        let size = NSMenuItem(title: "Pet size",action: nil,keyEquivalent: ""); let sizes = NSMenu()
        for (title,value) in [("Small",80),("Medium",100),("Large",125)] {
            let item = NSMenuItem(title: title,action: #selector(resizePet(_:)),keyEquivalent: ""); item.tag = value; item.target = self; sizes.addItem(item)
        }
        size.submenu = sizes; menu.addItem(size)
        add("Reset position",#selector(resetPosition)); menu.addItem(.separator()); add("Quit Tintin",#selector(quit))
        return menu
    }
    private func savePosition() {
        guard let panel else { return }; defaults.set(panel.frame.minX,forKey: "petX"); defaults.set(panel.frame.minY,forKey: "petY")
    }
    private func restorePosition() {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0,y: 0,width: 1200,height: 800)
        var origin = NSPoint(x: visible.maxX-panel.frame.width-30,y: visible.minY+15)
        if defaults.object(forKey: "petX") != nil {
            let proposed = NSPoint(x: defaults.double(forKey: "petX"),y: defaults.double(forKey: "petY"))
            let rect = NSRect(origin: proposed,size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(rect).width > 60 && $0.visibleFrame.intersection(rect).height > 60 }) { origin = proposed }
        }
        panel.setFrameOrigin(origin)
    }
}

// Apply network denial before creating AppKit, Metal, samplers, or login services.
var offlineError = [CChar](repeating:0,count:1024)
guard sm_offline_start(&offlineError,Int32(offlineError.count)) else {
    fputs("Offline security could not be applied; refusing to start: " + String(cString:offlineError) + "\n",stderr)
    exit(78)
}
if CommandLine.arguments.contains("--security-test") {
    let verified = sm_offline_verify()
    print(verified ? "PASS: IPv4/IPv6 TCP, UDP, and bind operations blocked by OS policy. No external traffic attempted." : "FAIL: network restriction verification failed")
    exit(verified ? 0 : 1)
}

if CommandLine.arguments.contains("--disable-login") {
    do { try SMAppService.mainApp.unregister(); print("Login launch: " + loginStatus()); exit(0) }
    catch { fputs("Login unregistration failed: \(error)\n",stderr); exit(1) }
}
if CommandLine.arguments.contains("--enable-login") {
    do { try SMAppService.mainApp.register(); print("Login launch: " + loginStatus()); exit(0) }
    catch { fputs("Login registration failed: \(error)\n",stderr); exit(1) }
}
if CommandLine.arguments.contains("--login-status") { print(loginStatus()); exit(0) }
if CommandLine.arguments.contains("--self-test") {
    let sampler = SystemSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 2.05)
    let r = sampler.sample()
    let payload: [String: Any] = ["networkPolicy":"deny network*; applied before app initialization","cpuPercent":r.cpu as Any? ?? NSNull(),"gpuPercent":r.gpu as Any? ?? NSNull(),"cpuTemperature":r.cpuTemperature as Any? ?? NSNull(),"gpuTemperature":r.gpuTemperature as Any? ?? NSNull(),"ramUsedBytes":r.memory?.usedBytes as Any? ?? NSNull(),"ramTotalBytes":r.memory?.totalBytes as Any? ?? NSNull(),"ramPercent":r.memory?.percent as Any? ?? NSNull(),"batteryPercent":r.battery?.percent as Any? ?? NSNull(),"batteryHealthPercentEstimate":r.battery?.healthPercent as Any? ?? NSNull(),"batteryCondition":r.battery?.condition as Any? ?? NSNull(),"batteryCycles":r.battery?.cycles as Any? ?? NSNull(),"batteryTemperature":r.battery?.power?.batteryTemperature as Any? ?? NSNull(),"systemWatts":r.battery?.power?.systemWatts as Any? ?? NSNull(),"adapterWatts":r.battery?.power?.adapterWatts as Any? ?? NSNull(),"adapterMaximumWatts":r.battery?.power?.adapterMaximumWatts as Any? ?? NSNull(),"topEnergy":r.topEnergy.map { ["name":$0.name,"watts":$0.value] as [String:Any] },"batteryCharging":r.battery?.charging as Any? ?? NSNull(),"batteryPluggedIn":r.battery?.pluggedIn as Any? ?? NSNull(),"cpuName":sampler.cpuName,"gpuName":sampler.gpuName,"processCount":r.processCount,"topCPU":r.topCPU.map { ["name":$0.name,"percentOfMachine":$0.value] as [String:Any] },"topGPU":r.topGPU.map { ["name":$0.name,"millisecondsPerSecond":$0.value] as [String:Any] },"diskBytesPerSecond":r.diskRate,"loginStatus":loginStatus()]
    let data = try JSONSerialization.data(withJSONObject: payload,options: [.prettyPrinted,.sortedKeys])
    print(String(decoding: data,as: UTF8.self)); exit(r.cpu == nil ? 1 : 0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
