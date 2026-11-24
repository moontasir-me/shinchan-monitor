import AppKit
import UserNotifications

final class HardwareAlertController: NSObject, UNUserNotificationCenterDelegate {
    private let defaults: UserDefaults
    private let engine: AlertEngine
    private var bubble: NSPanel?
    private var dismissTimer: Timer?
    private var settings: AlertSettingsController?
    private(set) var preferences: AlertPreferences
    private(set) var notificationStatus = "Checking macOS notifications…"
    private(set) var lastMessage = "No hardware alerts yet."
    var onOpenStats: (() -> Void)?
    var petFrame: (() -> NSRect)?
    var onState: ((Bool) -> Void)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; preferences = AlertPreferences(defaults:defaults)
        var saved: [AlertMetric: TimeInterval] = [:]
        for metric in AlertMetric.allCases {
            let time = defaults.double(forKey:"lastHardwareAlert." + metric.rawValue)
            if time > 0 { saved[metric] = time }
        }
        engine = AlertEngine(lastAlerts:saved)
        super.init()
    }
    func start() {
        UNUserNotificationCenter.current().delegate = self
        if preferences.enabled { requestNotifications() } else { refreshAuthorization() }
    }
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { [weak self] _,error in
            if let error { DispatchQueue.main.async { self?.notificationStatus = "Pet alerts available; macOS: " + error.localizedDescription; self?.settings?.refresh() } }
            else { self?.refreshAuthorization() }
        }
    }
    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] result in
            DispatchQueue.main.async {
                switch result.authorizationStatus {
                case .authorized, .provisional: self?.notificationStatus = "macOS notifications enabled · pet bubble also available"
                case .denied: self?.notificationStatus = "macOS banners off · pet bubbles still alert you"
                case .notDetermined: self?.notificationStatus = "Pet bubbles enabled · allow macOS banners if wanted"
                @unknown default: self?.notificationStatus = "Pet bubbles enabled · macOS status unknown"
                }
                self?.settings?.refresh()
            }
        }
    }
    func save(_ p: AlertPreferences) {
        let wasEnabled = preferences.enabled
        preferences = p; p.save(defaults); engine.resetQualification()
        onState?(false)
        if !p.enabled { bubble?.orderOut(nil); dismissTimer?.invalidate() }
        if p.enabled && !wasEnabled { requestNotifications() }
    }
    func process(_ reading: Reading) {
        var values: [AlertMetric: Double] = [:]
        values[.cpuUsage] = reading.cpu; values[.gpuUsage] = reading.gpu
        values[.cpuTemperature] = reading.cpuTemperature; values[.gpuTemperature] = reading.gpuTemperature
        let now = reading.date.timeIntervalSince1970
        let warnings = engine.evaluate(values:values,preferences:preferences,now:now)
        onState?(!engine.activeMetrics.isEmpty)
        guard !warnings.isEmpty else { return }
        for warning in warnings { defaults.set(now,forKey:"lastHardwareAlert." + warning.metric.rawValue) }
        let text = warnings.map { $0.message }.joined(separator:" ")
        let names = Array(Set((reading.topCPU+reading.topGPU).map { $0.name })).sorted().joined(separator:", ")
        deliver(title:"Shinchan: laptop working hard",message:text + (names.isEmpty ? "" : " Active apps: " + names + "."))
    }
    func testAlert() {
        deliver(title:"Shinchan test alert",message:"Test only — your laptop is not overheating. Real alerts warn about sustained high CPU, GPU, or temperature.")
    }
    private func deliver(title: String, message: String) {
        lastMessage = title + ": " + message
        showBubble(title:title,message:message)
        settings?.refresh()
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] status in
            guard let self else { return }
            let allowed = status.authorizationStatus == .authorized || status.authorizationStatus == .provisional
            if allowed {
                let content = UNMutableNotificationContent()
                content.title = title; content.body = message
                if self.preferences.sound { content.sound = .default }
                let request = UNNotificationRequest(identifier:"shinchan.hardware.warning",content:content,trigger:nil)
                UNUserNotificationCenter.current().add(request) { [weak self] error in
                    guard let error else { return }
                    DispatchQueue.main.async {
                        self?.notificationStatus = "Pet bubble shown · macOS notification failed: " + error.localizedDescription
                        if self?.preferences.sound == true { NSSound(named:"Pop")?.play() }
                        self?.settings?.refresh()
                    }
                }
            } else if self.preferences.sound {
                DispatchQueue.main.async { NSSound(named:"Pop")?.play() }
            }
        }
    }
    private func showBubble(title: String, message: String) {
        dismissTimer?.invalidate(); bubble?.orderOut(nil)
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:320,height:136),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.title = "Shinchan hardware alert"
        let bg = NSVisualEffectView(frame:panel.contentView!.bounds)
        bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true; bg.layer?.cornerRadius = 16
        bg.appearance = NSAppearance(named:.darkAqua); panel.contentView = bg
        let heading = label(title,size:13,weight:.bold,color:.systemOrange)
        heading.frame = NSRect(x:14,y:106,width:285,height:20); bg.addSubview(heading)
        let body = label(message,size:12)
        body.maximumNumberOfLines = 4; body.lineBreakMode = .byWordWrapping
        body.frame = NSRect(x:14,y:35,width:292,height:69); bg.addSubview(body)
        let inspect = NSButton(title:"Show laptop status",target:self,action:#selector(openStats))
        inspect.bezelStyle = .rounded; inspect.frame = NSRect(x:10,y:5,width:170,height:28); bg.addSubview(inspect)
        let dismiss = NSButton(title:"Dismiss",target:self,action:#selector(dismissBubble))
        dismiss.bezelStyle = .rounded; dismiss.frame = NSRect(x:220,y:5,width:90,height:28); bg.addSubview(dismiss)
        let pet = petFrame?() ?? NSRect(x:100,y:100,width:192,height:208)
        let screen = NSScreen.screens.first { $0.frame.intersects(pet) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        let x = min(screen.maxX-324,max(screen.minX+4,pet.midX-160))
        var y = pet.maxY-10
        if y+136 > screen.maxY { y = pet.minY-140 }
        y = max(screen.minY+4,min(screen.maxY-140,y))
        panel.setFrameOrigin(NSPoint(x:x,y:y)); panel.orderFrontRegardless(); bubble = panel
        dismissTimer = Timer.scheduledTimer(withTimeInterval:18,repeats:false) { [weak self] _ in self?.dismissBubble() }
    }
    @objc private func openStats() { dismissBubble(); onOpenStats?() }
    @objc private func dismissBubble() { bubble?.orderOut(nil); dismissTimer?.invalidate() }
    func showSettings() {
        if settings == nil { settings = AlertSettingsController(alerts:self) }
        settings?.refresh(); settings?.showWindow(nil); settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true); refreshAuthorization()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner,.list,.sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.onOpenStats?() }; completionHandler()
    }
}

final class AlertSettingsController: NSWindowController {
    private unowned let alerts: HardwareAlertController
    private let enabled = NSButton(checkboxWithTitle:"Enable hardware alerts",target:nil,action:nil)
    private let sound = NSButton(checkboxWithTitle:"Play alert sound",target:nil,action:nil)
    private var sliders: [AlertMetric:NSSlider] = [:]
    private var values: [AlertMetric:NSTextField] = [:]
    private let status = label("",size:11,color:.secondaryLabelColor)
    private let last = label("",size:11,color:.secondaryLabelColor)
    init(alerts: HardwareAlertController) {
        self.alerts = alerts
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:430,height:510),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Shinchan · Hardware alerts"; window.isReleasedWhenClosed = false
        super.init(window:window)
        window.center(); window.appearance = NSAppearance(named:.darkAqua)
        let root = window.contentView!
        func place(_ v:NSView,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat) { v.frame = NSRect(x:x,y:y,width:w,height:h); root.addSubview(v) }
        place(label("Let Shinchan warn you",size:21,weight:.bold),20,465,390,28)
        enabled.target = self; enabled.action = #selector(changed); place(enabled,18,430,395,24)
        for (index,metric) in AlertMetric.allCases.enumerated() {
            let y = CGFloat(383-index*58)
            place(label(metric.title,size:13,weight:.medium),22,y,260,21)
            let field = label("",size:13,weight:.semibold); field.alignment = .right; values[metric] = field
            place(field,333,y,70,21)
            let slider = NSSlider(value:metric.threshold(alerts.preferences),minValue:50,maxValue:metric.isTemperature ? 110 : 100,target:self,action:#selector(changed))
            slider.tag = index; slider.isContinuous = true; slider.setAccessibilityLabel(metric.title + " alert threshold")
            sliders[metric] = slider; place(slider,20,y-25,385,23)
        }
        let explanation = label("Usage must stay high for 30 seconds; temperature for 10 seconds. Each warning repeats at most once every 5 minutes. These are adjustable warning levels.",size:11,color:.secondaryLabelColor)
        explanation.maximumNumberOfLines = 3; explanation.lineBreakMode = .byWordWrapping; place(explanation,22,130,385,49)
        sound.target = self; sound.action = #selector(changed); place(sound,18,102,390,24)
        status.maximumNumberOfLines = 2; status.lineBreakMode = .byWordWrapping; place(status,22,62,385,37)
        last.maximumNumberOfLines = 2; last.lineBreakMode = .byTruncatingTail; place(last,22,25,170,33)
        let done = NSButton(title:"Done",target:self,action:#selector(done)); done.bezelStyle = .rounded; place(done,202,24,80,30)
        let test = NSButton(title:"Test alert",target:self,action:#selector(testAlert)); test.bezelStyle = .rounded; place(test,288,24,120,30)
        refresh()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        enabled.state = alerts.preferences.enabled ? .on : .off; sound.state = alerts.preferences.sound ? .on : .off
        for metric in AlertMetric.allCases {
            let value = metric.threshold(alerts.preferences)
            sliders[metric]?.doubleValue = value
            values[metric]?.stringValue = String(format:"%.0f%@",value,metric.isTemperature ? " °C" : "%")
            sliders[metric]?.isEnabled = alerts.preferences.enabled
        }
        status.stringValue = alerts.notificationStatus; last.stringValue = alerts.lastMessage; last.toolTip = alerts.lastMessage
    }
    @objc private func changed() {
        var p = alerts.preferences
        p.enabled = enabled.state == .on; p.sound = sound.state == .on
        p.cpuUsage = sliders[.cpuUsage]!.doubleValue.rounded(); p.gpuUsage = sliders[.gpuUsage]!.doubleValue.rounded()
        p.cpuTemperature = sliders[.cpuTemperature]!.doubleValue.rounded(); p.gpuTemperature = sliders[.gpuTemperature]!.doubleValue.rounded()
        alerts.save(p); refresh()
    }
    @objc private func testAlert() { window?.orderOut(nil); alerts.testAlert() }
    @objc private func done() { window?.orderOut(nil) }
}
