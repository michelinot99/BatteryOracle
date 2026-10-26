import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    // Live state
    @Published private(set) var battery: BatterySnapshot?
    @Published private(set) var outlook: Outlook?
    @Published private(set) var forecast: PowerForecast?
    @Published private(set) var bins: [Bin] = []
    @Published private(set) var isForecasting = false
    @Published private(set) var engineError: String?
    @Published private(set) var installLog: String?
    @Published private(set) var calibration = 1.0
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var popoverOpen = false { didSet { if popoverOpen { refreshIfStale(maxAge: 600) } } }

    // Preferences
    @AppStorage("endOfDayMinutes") var endOfDayMinutes = 19 * 60 { didSet { resimulate() } }
    @AppStorage("threshold") var threshold = 10.0 { didSet { resimulate() } }
    @AppStorage("model") var model = "mistralai/Timestral-5M" { didSet { forecastNow() } }
    @AppStorage("morningAlert") var morningAlert = true { didSet { requestNotifications() } }
    @AppStorage("morningMinutes") var morningMinutes = 8 * 60
    @AppStorage("liveAlert") var liveAlert = true { didSet { requestNotifications() } }
    @AppStorage("showPercent") var showPercent = true
    @AppStorage("lastMorningAlert") private var lastMorningAlert = ""
    @AppStorage("lastLiveAlert") private var lastLiveAlert = ""

    let demo = CommandLine.arguments.contains("--demo")
    let store: HistoryStore
    private var timers: [Timer] = []
    private var sleepWatts = 0.3
    private var lastWakeHandled = Date.distantPast

    /// False during dark wakes (Power Nap, mail checks…) and with the lid closed: macOS wakes the Mac
    /// for a few seconds with the display off, and nobody is there to read an alert or benefit from a forecast.
    private var userPresent: Bool { demo || CGDisplayIsAsleep(CGMainDisplayID()) == 0 }

    init() {
        store = HistoryStore(directory: TimestralEngine.support, demo: CommandLine.arguments.contains("--demo"))
        sample()
        rebuildBins()
        forecastNow()

        // One light poll every two minutes; the generous tolerance lets the system coalesce it with other wake-ups.
        let poll = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        poll.tolerance = 60
        RunLoop.main.add(poll, forMode: .common)
        timers.append(poll)

        PowerSourceObserver.start()
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
        nc.addObserver(forName: .powerSourceChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sample(); self?.resimulate() }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // Dark wakes end in another sleep: keep the original marker so the whole night counts as one sleep.
                guard self?.store.samples.last?.kind != .sleep else { return }
                self?.sample(kind: .sleep)
            }
        }
        // A real wake brings the display up, possibly just after didWake, so listen to both.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleWake() }
            }
        }
    }

    private func handleWake() {
        guard userPresent, Date().timeIntervalSince(lastWakeHandled) > 5 else { return }
        lastWakeHandled = Date()
        if store.samples.last?.kind == .sleep { sample(kind: .wake) } else { sample() }
        rebuildBins()
        resimulate()
        if !refreshIfStale(maxAge: 3600) { checkAlerts() }
    }

    // MARK: - Sampling

    private func tick() {
        guard userPresent else { return }
        sample()
        resimulate()
        if !refreshIfStale(maxAge: battery?.plugged == false ? 3600 : 3 * 3600) { checkAlerts() }
    }

    func sample(kind: Sample.Kind = .reading) {
        guard var b = BatteryReader.read() else { return }
        if demo, let last = store.samples.last {  // pretend we're out and about, on battery
            (b.level, b.plugged, b.charging, b.systemWatts) = (last.level, false, false, last.watts)
        }
        battery = b
        guard !demo else { return }
        store.append(Sample(time: b.date.timeIntervalSince1970, level: b.level, plugged: b.plugged,
                            charging: b.charging, watts: kind == .sleep ? nil : b.systemWatts, kind: kind))
    }

    private func rebuildBins() {
        let wh = battery?.fullChargeWh ?? 50
        sleepWatts = store.sleepWatts(fullChargeWh: wh)
        bins = store.bins(sleepWatts: sleepWatts)
        calibration = store.calibration(fullChargeWh: wh, bins: bins)
    }

    var learningProgress: Double { min(1, store.span / (3 * 86400)) }
    var hasEnoughData: Bool { bins.compactMap(\.watts).count >= 8 }

    // MARK: - Forecasting

    /// Starts a new forecast if the current one is older than `maxAge`; returns whether one is on its way.
    @discardableResult
    func refreshIfStale(maxAge: TimeInterval) -> Bool {
        if let f = forecast, Date().timeIntervalSince(f.created) <= maxAge { return false }
        forecastNow()
        return isForecasting
    }

    func forecastNow() {
        guard !isForecasting else { return }
        rebuildBins()
        guard hasEnoughData else { outlook = nil; return }
        isForecasting = true
        let bins = self.bins, model = self.model
        let horizon = 96 + 8   // a day ahead, plus slack so an hour-old forecast still reaches tonight
        Task {
            do {
                forecast = try await TimestralEngine.forecast(bins: bins, horizon: horizon, model: model)
                engineError = nil
            } catch {
                if case EngineError.missing = error { engineError = nil } else { engineError = error.localizedDescription }
                forecast = ProfileForecaster.forecast(bins: bins, horizon: horizon)
            }
            isForecasting = false
            resimulate()
            checkAlerts()
        }
    }

    private func today(at minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())!
    }

    var batteryTint: BatteryTint {
        if let b = battery, !b.charging, b.level <= threshold { return .low }
        return lowPowerMode ? .lowPower : .normal
    }

    /// Once today's end of day has passed, the question becomes tomorrow, after a night on the charger.
    var planningTomorrow: Bool { today(at: endOfDayMinutes) <= Date().addingTimeInterval(15 * 60) }

    var endOfDay: Date {
        let end = today(at: endOfDayMinutes)
        return planningTomorrow ? Calendar.current.date(byAdding: .day, value: 1, to: end)! : end
    }

    func resimulate() {
        guard let f = forecast, let b = battery else { return }
        let morning = planningTomorrow ? Calendar.current.date(byAdding: .day, value: 1, to: today(at: morningMinutes)) : nil
        outlook = Outlook(forecast: f, level: morning == nil ? b.level : 100, fullChargeWh: b.fullChargeWh,
                          calibration: calibration, threshold: threshold, endOfDay: endOfDay, tomorrowFrom: morning)
    }

    /// Battery level over the last 12 hours, for the chart.
    var recentLevels: [(date: Date, level: Double)] {
        let cutoff = Date().addingTimeInterval(-12 * 3600).timeIntervalSince1970
        let recent = store.samples.filter { $0.time >= cutoff }
        let stride = Swift.max(1, recent.count / 120)
        return Swift.stride(from: 0, to: recent.count, by: stride).map {
            (Date(timeIntervalSince1970: recent[$0].time), recent[$0].level)
        } + (battery.map { [($0.date, $0.level)] } ?? [])
    }

    // MARK: - Notifications

    private func requestNotifications() {
        guard (morningAlert || liveAlert), Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkAlerts() {
        guard userPresent, let o = outlook, let b = battery, Bundle.main.bundleIdentifier != nil, !demo else { return }
        let today = Date().formatted(.iso8601.year().month().day())
        let minutes = Calendar.current.component(.hour, from: Date()) * 60 + Calendar.current.component(.minute, from: Date())
        let end = endOfDay.formatted(date: .omitted, time: .shortened)

        if morningAlert, lastMorningAlert != today, minutes >= morningMinutes, minutes < endOfDayMinutes {
            lastMorningAlert = today
            if o.verdict != .fine {
                notify(o.verdict == .charger ? "Oggi porta il caricabatterie" : "Oggi potresti restare a secco",
                       "Alle \(end) si prevede il \(Int(o.levelAtEnd))%: \(Int(o.probability * 100))% di probabilità di arrivarci sopra il \(Int(threshold))%.")
            }
        }
        if liveAlert, lastLiveAlert != today, !b.plugged, o.probability < 0.4, let when = o.reachesThreshold, when < endOfDay {
            lastLiveAlert = today
            notify("A questo ritmo non arrivi alle \(end)",
                   "Scenderai sotto il \(Int(threshold))% verso le \(when.formatted(date: .omitted, time: .shortened)). Meglio ricaricare prima.")
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: - Settings actions

    /// macOS offers no public API to flip Low Power Mode. If the Shortcuts app has "BatteryOracle risparmio on" and
    /// "BatteryOracle risparmio off" (one "Imposta modalità risparmio energetico" action each) they are run, which
    /// needs no password. Otherwise `pmset` runs as administrator and the system asks for the password every time.
    func toggleLowPowerMode() {
        let target = lowPowerMode ? 0 : 1
        Task.detached {
            func run(_ exe: String, _ args: [String]) -> Bool {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.standardError = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return false }
                p.waitUntilExit()
                return p.terminationStatus == 0
            }
            if !run("/usr/bin/shortcuts", ["run", "BatteryOracle risparmio \(target == 1 ? "on" : "off")"]) {
                _ = run("/usr/bin/osascript", ["-e", "do shell script \"/usr/bin/pmset -a lowpowermode \(target)\" with administrator privileges"])
            }
            await MainActor.run { self.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            objectWillChange.send()
        }
    }
    var canLaunchAtLogin: Bool { Bundle.main.bundleIdentifier != nil }

    var engineInstalled: Bool { TimestralEngine.isInstalled }

    func installEngine() {
        guard installLog == nil, let script = TimestralEngine.resource("setup-engine.sh", "scripts") else { return }
        installLog = "Preparazione…"
        Task {
            do {
                _ = try await TimestralEngine.run(URL(fileURLWithPath: "/bin/zsh"), [script.path, model],
                                                  timeout: 1800) { line in
                    Task { @MainActor in self.installLog = line }
                }
            } catch {
                engineError = error.localizedDescription
            }
            installLog = nil
            forecastNow()
        }
    }
}
