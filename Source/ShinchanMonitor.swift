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
    var processCount = 0
    var diskRate = 0.0
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
        r.topCPU = top(cpu); r.topGPU = top(gpu)
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

    func sample() -> Reading { details.enrich(Reading(cpu: readCPU(), gpu: readGPU(), date: Date())) }
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

final class StatsController: NSViewController {
    let cpuCard: MetricCard
    let gpuCard: MetricCard
    private let temperatures = label("CPU — °C     GPU — °C", size: 17, weight: .semibold)
    private let cpuApps = label("Sampling apps…", size: 12)
    private let gpuApps = label("Sampling apps…", size: 12)
    private let activity = label("Reading this Mac…", size: 12)
    private let sizeLabel = label("Pet size · 100%", size: 12)
    private let slider = NSSlider(value: 100, minValue: 50, maxValue: 200, target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Start automatically at login", target: nil, action: nil)
    private let loginDetail = label("", size: 11, color: .secondaryLabelColor)
    var onClose: (() -> Void)?
    var onSize: ((Double) -> Void)?
    var onAlerts: (() -> Void)?
    init(cpuName: String, gpuName: String) {
        cpuCard = MetricCard(title: "CPU", detail: cpuName, symbol: "cpu", tint: .systemCyan)
        gpuCard = MetricCard(title: "GPU", detail: gpuName, symbol: "display", tint: .systemOrange)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 344, height: 680))
        background.material = .popover; background.blendingMode = .behindWindow; background.state = .active
        background.appearance = NSAppearance(named: .darkAqua); view = background
        func place(_ v: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            v.frame = NSRect(x:x,y:y,width:w,height:h); background.addSubview(v)
        }
        place(label("Shinchan", size: 21, weight: .bold),18,639,180,28)
        let alerts = NSButton(title:"Alerts…",target:self,action:#selector(openAlerts)); alerts.bezelStyle = .rounded
        place(alerts,211,639,85,28)
        place(label("Your local laptop companion",size:12,color:.secondaryLabelColor),18,619,290,18)
        let close = NSButton(image: NSImage(systemSymbolName:"xmark.circle.fill", accessibilityDescription:"Close statistics")!,target:self,action:#selector(closePanel))
        close.isBordered = false; place(close,303,643,23,23)
        place(temperatures,18,582,310,27)
        temperatures.toolTip = "Average of available CPU and GPU die sensors. A dash means the sensor is unavailable."
        place(cpuCard,16,471,312,103)
        place(cpuApps,22,422,300,44); cpuApps.maximumNumberOfLines = 2
        cpuApps.toolTip = "Top two apps by CPU usage across total machine capacity; helper processes grouped by application."
        place(gpuCard,16,311,312,103)
        place(gpuApps,22,262,300,44); gpuApps.maximumNumberOfLines = 2
        gpuApps.toolTip = "Top two apps by measured GPU time, in milliseconds per second. Parallel GPU work can overlap."
        place(label("CURRENT ACTIVITY",size:10,weight:.semibold,color:.secondaryLabelColor),20,239,300,17)
        place(activity,20,164,304,73); activity.maximumNumberOfLines = 4; activity.lineBreakMode = .byWordWrapping
        place(sizeLabel,20,138,304,20)
        slider.target = self; slider.action = #selector(changeSize); slider.isContinuous = true
        slider.setAccessibilityLabel("Pet size percent"); place(slider,18,110,308,25)
        login.target = self; login.action = #selector(changeLogin); place(login,18,77,310,24)
        place(loginDetail,22,57,300,18)
        let monitor = NSButton(title:"Activity Monitor",target:self,action:#selector(openMonitor)); monitor.bezelStyle = .rounded
        place(monitor,16,15,147,28)
        let downloads = NSButton(title:"Downloads",target:self,action:#selector(openDownloads)); downloads.bezelStyle = .rounded
        place(downloads,174,15,154,28)
        preferredContentSize = background.frame.size
        setScale(UserDefaults.standard.double(forKey:"petScale"))
        refreshLogin()
    }
    @objc private func closePanel() { onClose?() }
    @objc private func openAlerts() { onAlerts?() }
    @objc private func changeSize() { setScale(slider.doubleValue/100); onSize?(slider.doubleValue/100) }
    func setScale(_ value: Double) {
        let scale = value == 0 ? 1 : value
        slider.doubleValue = scale*100; sizeLabel.stringValue = "Pet size · \(Int(scale*100))%"
    }
    func refreshLogin() {
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginDetail.stringValue = "Login launch: " + loginStatus()
    }
    @objc private func changeLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLogin()
        } catch { loginDetail.stringValue = error.localizedDescription; refreshLogin() }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    @objc private func openMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Utilities/Activity Monitor.app")) }
    @objc private func openDownloads() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) }
    func update(_ r: Reading) {
        _ = view
        cpuCard.update(r.cpu); gpuCard.update(r.gpu)
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
    }
}

final class PetView: NSView {
    private let atlas: NSImage
    private var images: [String: [NSImage]] = [:]
    private let durations: [String: [Double]] = [
        "idle": [0.28,0.11,0.11,0.14,0.14,0.32],
        "waving": [0.14,0.14,0.14,0.28],
        "running": [0.12,0.12,0.12,0.12,0.12,0.22]
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
    var showsStatistics = false
    var onClick: (() -> Void)?
    var onMove: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    init(atlasURL: URL) throws {
        guard let loaded = NSImage(contentsOf: atlasURL), let bitmap = NSBitmapImageRep(data: try Data(contentsOf: atlasURL)), bitmap.pixelsWide == 1536, bitmap.pixelsHigh == 2288 else {
            throw NSError(domain: "ShinchanMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "The pet sprite sheet is missing or has the wrong dimensions."])
        }
        atlas = loaded
        super.init(frame: NSRect(x: 0, y: 0, width: 192, height: 208))
        for (name, row, count) in [("idle",0,6),("waving",3,4),("running",7,6),("look-a",9,8),("look-b",10,8)] {
            images[name] = (0..<count).map { col in
                let frame = NSImage(size: NSSize(width: 192, height: 208))
                frame.lockFocus()
                atlas.draw(in: NSRect(x: 0,y: 0,width: 192,height: 208), from: NSRect(x: col*192,y: 2288-(row+1)*208,width: 192,height: 208), operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
                frame.unlockFocus(); return frame
            }
        }
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("Shinchan. Click for CPU and GPU usage. Drag to move. Right-click for options.")
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
        var desired = showsStatistics ? "running" : (now < waveUntil ? "waving" : "idle")
        var lookIndex: Int?
        if desired == "idle", let window {
            let mouse = NSEvent.mouseLocation
            let center = NSPoint(x: window.frame.midX,y: window.frame.minY+window.frame.height*0.6)
            let dx = mouse.x-center.x; let dy = mouse.y-center.y
            let distance = hypot(dx,dy)
            if distance > 100 && distance < 330 {
                var degrees = atan2(dx,dy)*180 / .pi
                if degrees < 0 { degrees += 360 }
                let direction = Int((degrees/22.5).rounded()) % 16
                desired = direction < 8 ? "look-a" : "look-b"; lookIndex = direction % 8
            }
        }
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
        frames[index].draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
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
    private let sampleQueue = DispatchQueue(label: "local.shinchan.monitor.sampling", qos: .utility)
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.shinchan.monitor").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }
        guard let sprite = Bundle.main.url(forResource: "spritesheet",withExtension: "png") else { fail("The pet artwork is missing."); return }
        do { pet = try PetView(atlasURL: sprite) } catch { fail(error.localizedDescription); return }
        panel = PetPanel(contentRect: NSRect(x: 0,y: 0,width: 192,height: 208), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Shinchan Desktop Pet"
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
            self?.statusItem?.button?.title = active ? "⚠️" : "🐾"
            self?.statusItem?.button?.toolTip = active ? "Shinchan · High hardware usage or temperature" : "Shinchan · CPU and GPU usage"
        }
        stats.onSize = { [weak self] scale in self?.setSize(scale); self?.savePosition() }
        popover.contentViewController = stats; popover.behavior = .transient; popover.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"; statusItem.button?.toolTip = "Shinchan · CPU and GPU usage"
        statusItem.menu = menu()
        setSize(defaults.double(forKey: "petScale") == 0 ? 1 : defaults.double(forKey: "petScale"))
        restorePosition(); panel.orderFrontRegardless()
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
        let alert = NSAlert(); alert.messageText = "Shinchan couldn’t start"; alert.informativeText = message; alert.runModal(); NSApp.terminate(nil)
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
        add("Show CPU & GPU usage",#selector(toggleStats)); add("Hardware alerts…",#selector(showAlerts)); add("Show Shinchan",#selector(showPet))
        let size = NSMenuItem(title: "Pet size",action: nil,keyEquivalent: ""); let sizes = NSMenu()
        for (title,value) in [("Small",80),("Medium",100),("Large",125)] {
            let item = NSMenuItem(title: title,action: #selector(resizePet(_:)),keyEquivalent: ""); item.tag = value; item.target = self; sizes.addItem(item)
        }
        size.submenu = sizes; menu.addItem(size)
        add("Reset position",#selector(resetPosition)); menu.addItem(.separator()); add("Quit Shinchan",#selector(quit))
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
    let payload: [String: Any] = ["cpuPercent":r.cpu as Any? ?? NSNull(),"gpuPercent":r.gpu as Any? ?? NSNull(),"cpuTemperature":r.cpuTemperature as Any? ?? NSNull(),"gpuTemperature":r.gpuTemperature as Any? ?? NSNull(),"cpuName":sampler.cpuName,"gpuName":sampler.gpuName,"processCount":r.processCount,"topCPU":r.topCPU.map { ["name":$0.name,"percentOfMachine":$0.value] as [String:Any] },"topGPU":r.topGPU.map { ["name":$0.name,"millisecondsPerSecond":$0.value] as [String:Any] },"diskBytesPerSecond":r.diskRate,"loginStatus":loginStatus()]
    let data = try JSONSerialization.data(withJSONObject: payload,options: [.prettyPrinted,.sortedKeys])
    print(String(decoding: data,as: UTF8.self)); exit(r.cpu == nil ? 1 : 0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
