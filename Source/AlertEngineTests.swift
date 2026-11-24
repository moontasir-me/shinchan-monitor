import Foundation

@main struct AlertEngineTests {
    static func main() {
        var count = 0
        func check(_ result: @autoclosure () -> Bool, _ message: String) {
            guard result() else { fatalError(message) }; count += 1
        }
        var p = AlertPreferences()
        let e = AlertEngine()
        var hits: [HardwareWarning] = []
        for t in stride(from: 0.0,through: 30.0,by:2) { hits += e.evaluate(values:[.cpuUsage:95],preferences:p,now:t) }
        check(hits.count == 1 && hits[0].metric == .cpuUsage,"CPU sustained trigger")
        check(e.evaluate(values:[.cpuUsage:95],preferences:p,now:32).isEmpty,"No repeated alert")
        // Continuous high load may remind after five minutes, not every sample.
        for t in stride(from:34.0,through:328.0,by:2) { check(e.evaluate(values:[.cpuUsage:95],preferences:p,now:t).isEmpty,"Cooldown") }
        check(e.evaluate(values:[.cpuUsage:95],preferences:p,now:330).count == 1,"Cooldown reminder")
        _ = e.evaluate(values:[.cpuUsage:88],preferences:p,now:332)
        check(e.activeMetrics.contains(.cpuUsage),"Recovery hysteresis")
        _ = e.evaluate(values:[.cpuUsage:85],preferences:p,now:334)
        check(e.activeMetrics.isEmpty,"Recovered")
        let temps = AlertEngine()
        for t in stride(from:0.0,through:8.0,by:2) { check(temps.evaluate(values:[.cpuTemperature:90,.gpuTemperature:90],preferences:p,now:t).isEmpty,"Temperature dwell") }
        check(temps.evaluate(values:[.cpuTemperature:90,.gpuTemperature:90],preferences:p,now:10).count == 2,"Both temperature triggers")
        let spikes = AlertEngine()
        for t in stride(from:0.0,through:40.0,by:2) {
            check(spikes.evaluate(values:[.gpuUsage:t == 10 ? 20 : 95],preferences:p,now:t).isEmpty,"Spike resets usage dwell")
        }
        check(spikes.evaluate(values:[.gpuUsage:95],preferences:p,now:42).count == 1,"GPU sustained trigger")
        let gaps = AlertEngine()
        _ = gaps.evaluate(values:[.gpuTemperature:95],preferences:p,now:0)
        check(gaps.evaluate(values:[.gpuTemperature:95],preferences:p,now:60).isEmpty,"Sleep gap resets qualification")
        _ = gaps.evaluate(values:[:],preferences:p,now:62)
        check(gaps.activeMetrics.isEmpty,"Missing sensor clears state")
        p.enabled = false
        check(temps.evaluate(values:[.cpuTemperature:99],preferences:p,now:12).isEmpty && temps.activeMetrics.isEmpty,"Disabled")
        let suite = "local.shinchan.alert-tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName:suite)!
        defer { d.removePersistentDomain(forName:suite) }
        p.cpuUsage = 97; p.save(d)
        check(AlertPreferences(defaults:d).cpuUsage == 97 && !AlertPreferences(defaults:d).enabled,"Preferences persist")
        let persisted = AlertEngine(lastAlerts:[.cpuTemperature:0])
        p.enabled = true
        for t in stride(from:20.0,through:40.0,by:2) { check(persisted.evaluate(values:[.cpuTemperature:99],preferences:p,now:t).isEmpty,"Cooldown survives restart") }
        print("Passed \(count) alert checks: dwell, all four metrics, cooldown, recovery, missing sensors, sleep gaps, disable, persistence.")
    }
}
