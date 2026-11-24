import Foundation

// Preferences are warning levels, not hardware shutdown/safety limits.
struct AlertPreferences {
    var enabled = true
    var sound = true
    var cpuUsage = 90.0
    var gpuUsage = 90.0
    var cpuTemperature = 85.0
    var gpuTemperature = 85.0
    static let cooldown: TimeInterval = 300
    init(defaults: UserDefaults? = nil) {
        guard let d = defaults else { return }
        enabled = d.object(forKey: "alertsEnabled") == nil || d.bool(forKey: "alertsEnabled")
        sound = d.object(forKey: "alertSound") == nil || d.bool(forKey: "alertSound")
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard d.object(forKey: key) != nil else { return fallback }
            return min(range.upperBound, max(range.lowerBound, d.double(forKey: key)))
        }
        cpuUsage = number("alertCPUUsage",90,50...100)
        gpuUsage = number("alertGPUUsage",90,50...100)
        cpuTemperature = number("alertCPUTemperature",85,50...110)
        gpuTemperature = number("alertGPUTemperature",85,50...110)
    }
    func save(_ d: UserDefaults) {
        d.set(enabled,forKey:"alertsEnabled"); d.set(sound,forKey:"alertSound")
        d.set(cpuUsage,forKey:"alertCPUUsage"); d.set(gpuUsage,forKey:"alertGPUUsage")
        d.set(cpuTemperature,forKey:"alertCPUTemperature"); d.set(gpuTemperature,forKey:"alertGPUTemperature")
    }
}

enum AlertMetric: String, CaseIterable {
    case cpuUsage, gpuUsage, cpuTemperature, gpuTemperature
    var title: String {
        switch self {
        case .cpuUsage: return "CPU usage"
        case .gpuUsage: return "GPU usage"
        case .cpuTemperature: return "CPU temperature"
        case .gpuTemperature: return "GPU temperature"
        }
    }
    var isTemperature: Bool { self == .cpuTemperature || self == .gpuTemperature }
    var hold: TimeInterval { isTemperature ? 10 : 30 }
    var hysteresis: Double { isTemperature ? 3 : 5 }
    func threshold(_ p: AlertPreferences) -> Double {
        switch self {
        case .cpuUsage: return p.cpuUsage
        case .gpuUsage: return p.gpuUsage
        case .cpuTemperature: return p.cpuTemperature
        case .gpuTemperature: return p.gpuTemperature
        }
    }
}

struct HardwareWarning {
    let metric: AlertMetric
    let value: Double
    let limit: Double
    var message: String {
        String(format: "%@ is %.0f%@ (limit %.0f%@).", metric.title,value,metric.isTemperature ? " °C" : "%",limit,metric.isTemperature ? " °C" : "%")
    }
}

// Pure state machine: time is injected so tests never heat or stress the laptop.
final class AlertEngine {
    private struct State {
        var since: TimeInterval?
        var active = false
        var lastAlert: TimeInterval?
    }
    private var states: [AlertMetric: State] = [:]
    private var lastSample: TimeInterval?
    init(lastAlerts: [AlertMetric: TimeInterval] = [:]) {
        for (metric,time) in lastAlerts { var s = State(); s.lastAlert = time; states[metric] = s }
    }
    var activeMetrics: Set<AlertMetric> { Set(states.filter { $0.value.active }.map { $0.key }) }
    func resetQualification() {
        for key in Array(states.keys) { states[key]?.since = nil; states[key]?.active = false }
        lastSample = nil
    }
    func evaluate(values: [AlertMetric: Double], preferences p: AlertPreferences, now: TimeInterval) -> [HardwareWarning] {
        guard p.enabled else { resetQualification(); return [] }
        if let lastSample, now < lastSample || now-lastSample > 6 { resetQualification() }
        lastSample = now
        var warnings: [HardwareWarning] = []
        for metric in AlertMetric.allCases {
            var s = states[metric] ?? State()
            defer { states[metric] = s }
            guard let value = values[metric], value.isFinite else { s.since = nil; s.active = false; continue }
            let limit = metric.threshold(p)
            if value < limit {
                s.since = nil
                if value <= limit-metric.hysteresis { s.active = false }
                continue
            }
            if s.since == nil { s.since = now }
            guard now-(s.since ?? now) >= metric.hold else { continue }
            s.active = true
            if let last = s.lastAlert, now-last < AlertPreferences.cooldown { continue }
            s.lastAlert = now
            warnings.append(HardwareWarning(metric:metric,value:value,limit:limit))
        }
        return warnings
    }
}
