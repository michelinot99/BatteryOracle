import Foundation

/// A logged reading. `kind` marks the moments the Mac goes to sleep and wakes up,
/// so the hours spent asleep count as near-zero draw instead of missing data.
struct Sample {
    enum Kind: Int { case reading = 0, sleep = 1, wake = 2 }
    var time: TimeInterval
    var level: Double
    var plugged: Bool
    var charging: Bool
    var watts: Double?
    var kind: Kind

    var csv: String {
        "\(Int(time)),\(Int(level)),\(plugged ? 1 : 0),\(charging ? 1 : 0),\(watts.map { String(format: "%.2f", $0) } ?? ""),\(kind.rawValue)\n"
    }

    init(time: TimeInterval, level: Double, plugged: Bool, charging: Bool, watts: Double?, kind: Kind) {
        (self.time, self.level, self.plugged, self.charging, self.watts, self.kind) = (time, level, plugged, charging, watts, kind)
    }

    init?(csv line: Substring) {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 6, let t = Double(f[0]), let l = Double(f[1]) else { return nil }
        self.init(time: t, level: l, plugged: f[2] == "1", charging: f[3] == "1",
                  watts: Double(f[4]), kind: Kind(rawValue: Int(f[5]) ?? 0) ?? .reading)
    }
}

/// A 15-minute slot of the power series that feeds the model.
struct Bin {
    var start: TimeInterval
    var watts: Double?     // average draw, nil when nothing was observed
    var plugged: Bool?
    var level: Double?     // battery level at the end of the slot
}

/// Append-only CSV log, kept to the last `retention` days and held in memory once loaded.
final class HistoryStore {
    static let step: TimeInterval = 900
    let url: URL
    let retention: TimeInterval = 30 * 86400
    private(set) var samples: [Sample] = []
    private var handle: FileHandle?

    init(directory: URL, demo: Bool = false) {
        url = directory.appendingPathComponent("history.csv")
        if demo { samples = DemoData.samples(); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return
        }
        let cutoff = Date().timeIntervalSince1970 - retention
        let all = text.split(separator: "\n").compactMap(Sample.init(csv:))
        samples = all.filter { $0.time >= cutoff }
        if samples.count < all.count {  // compact once at launch rather than on every write
            try? samples.map(\.csv).joined().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func append(_ s: Sample) {
        if let last = samples.last, s.time <= last.time { return }
        samples.append(s)
        handle?.write(Data(s.csv.utf8))
    }

    var span: TimeInterval { (samples.last?.time ?? 0) - (samples.first?.time ?? 0) }

    // MARK: - Power series

    /// Integrates the samples into 15-minute average power, holding each reading until the next one.
    /// Gaps longer than 10 minutes without a sleep marker are left unknown (the app wasn't running).
    func bins(until end: TimeInterval = Date().timeIntervalSince1970, sleepWatts: Double) -> [Bin] {
        guard let first = samples.first else { return [] }
        let step = Self.step
        let t0 = (first.time / step).rounded(.down) * step
        let count = Int(((end - t0) / step).rounded(.up))
        guard count > 0 else { return [] }
        var energy = [Double](repeating: 0, count: count)
        var covered = [Double](repeating: 0, count: count)
        var out = (0..<count).map { Bin(start: t0 + Double($0) * step) }

        func spread(_ a: TimeInterval, _ b: TimeInterval, watts: Double) {
            var t = a
            while t < b {
                let i = Int((t - t0) / step)
                guard i >= 0 && i < count else { return }
                let binEnd = t0 + Double(i + 1) * step
                let dt = min(b, binEnd) - t
                energy[i] += watts * dt
                covered[i] += dt
                t += dt
            }
        }

        for (i, s) in samples.enumerated() {
            let idx = Int((s.time - t0) / step)
            if idx >= 0 && idx < count {
                out[idx].plugged = s.plugged
                out[idx].level = s.level
            }
            let next = i + 1 < samples.count ? samples[i + 1].time : min(end, s.time + 120)
            if s.kind == .sleep {
                spread(s.time, next, watts: sleepWatts)
            } else if let w = s.watts, next - s.time <= 600 {
                spread(s.time, next, watts: w)
            }
        }
        for i in 0..<count where covered[i] >= step / 3 {
            out[i].watts = energy[i] / covered[i]
        }
        // Carry the last known plug state and level forward so the covariate has no holes.
        var lastPlug: Bool?, lastLevel: Double?
        for i in 0..<count {
            if let p = out[i].plugged { lastPlug = p } else { out[i].plugged = lastPlug }
            if let l = out[i].level { lastLevel = l } else { out[i].level = lastLevel }
        }
        return out
    }

    // MARK: - Learned constants

    /// Median draw while asleep, measured from the battery drop across long sleeps on battery.
    func sleepWatts(fullChargeWh: Double) -> Double {
        var rates: [Double] = []
        for (i, s) in samples.enumerated() where s.kind == .sleep && !s.plugged && i + 1 < samples.count {
            let w = samples[i + 1]
            let hours = (w.time - s.time) / 3600
            guard !w.plugged, hours >= 2 else { continue }
            rates.append(max(0, s.level - w.level) / 100 * fullChargeWh / hours)
        }
        return min(2, max(0.05, rates.median ?? 0.3))
    }

    /// How the measured battery drop compares with the integrated system power over long unplugged stretches.
    /// Corrects for adapter-side telemetry and the rough Wh estimate. 1 = perfect agreement.
    func calibration(fullChargeWh: Double, bins: [Bin]) -> Double {
        var ratios: [Double] = []
        var runStart: Int?
        for i in 0...bins.count {
            let onBattery = i < bins.count && bins[i].plugged == false && bins[i].watts != nil
            if onBattery { if runStart == nil { runStart = i }; continue }
            guard let s = runStart else { continue }
            runStart = nil
            let run = bins[s..<i]
            guard run.count >= 4, let l0 = run.first?.level, let l1 = run.last?.level, l0 - l1 >= 5 else { continue }
            // The first bin's level is its end value, so integrate from the second bin on.
            let predicted = run.dropFirst().compactMap(\.watts).reduce(0, +) * 0.25
            guard predicted > 0 else { continue }
            ratios.append((l0 - l1) / 100 * fullChargeWh / predicted)
        }
        return min(1.6, max(0.6, ratios.median ?? 1))
    }
}

// MARK: - Habits

struct HourlyHabit: Identifiable { let hour: Int; let watts: Double; var id: Int { hour } }
struct DailyUsage: Identifiable {
    let day: Date; let batteryWh: Double; let adapterWh: Double
    var id: Date { day }
    var total: Double { batteryWh + adapterWh }
}

extension Array where Element == Bin {
    func hourlyProfile(days: Int = 14) -> [HourlyHabit] {
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400
        var sum = [Double](repeating: 0, count: 24), n = [Double](repeating: 0, count: 24)
        let cal = Calendar.current
        for b in self where b.start >= cutoff {
            guard let w = b.watts else { continue }
            let h = cal.component(.hour, from: Date(timeIntervalSince1970: b.start))
            sum[h] += w; n[h] += 1
        }
        return (0..<24).map { HourlyHabit(hour: $0, watts: n[$0] > 0 ? sum[$0] / n[$0] : 0) }
    }

    func dailyUsage(days: Int = 10) -> [DailyUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().map { back in
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            let a = day.timeIntervalSince1970, b = a + 86400
            var bat = 0.0, ac = 0.0
            for bin in self where bin.start >= a && bin.start < b {
                guard let w = bin.watts else { continue }
                if bin.plugged == true { ac += w * 0.25 } else { bat += w * 0.25 }
            }
            return DailyUsage(day: day, batteryWh: bat, adapterWh: ac)
        }
    }
}

extension Array where Element == Double {
    var median: Double? {
        guard !isEmpty else { return nil }
        let s = sorted()
        return count % 2 == 1 ? s[count / 2] : (s[count / 2 - 1] + s[count / 2]) / 2
    }

    func quantile(_ q: Double) -> Double {
        guard !isEmpty else { return 0 }
        let s = sorted()
        let pos = q * Double(count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }
}

// MARK: - Demo

/// Two weeks of a plausible routine, for screenshots and for trying the app on a fresh install.
enum DemoData {
    static func samples() -> [Sample] {
        var out: [Sample] = []
        let cal = Calendar.current
        let now = Date().timeIntervalSince1970
        var t = (now - 14 * 86400) / 60 * 60
        var level = 100.0
        var rng = SystemRandomNumberGenerator()
        var asleep = false
        while t < now {
            let d = Date(timeIntervalSince1970: t)
            let h = Double(cal.component(.hour, from: d)) + Double(cal.component(.minute, from: d)) / 60
            let weekend = cal.isDateInWeekend(d)
            let awake = weekend ? (10...23).contains(h) : (8.5...22.5).contains(h)
            let plugged = weekend ? (h < 9 || h >= 21 || (13...14).contains(h)) : (h < 9 || h >= 19.5 || (13...13.75).contains(h))
            if !awake {
                if !asleep { out.append(Sample(time: t, level: level, plugged: plugged, charging: false, watts: nil, kind: .sleep)); asleep = true }
                if plugged { level = min(100, level + 0.8) } else { level = max(1, level - 0.004) }
                t += 120; continue
            }
            let base = weekend ? 3.8 : (h < 13 ? 4.6 : h < 17 ? 6.2 : 4.4)
            let watts = max(1.5, base + Double.random(in: -1.5...2.5, using: &rng))
            if plugged { level = min(100, level + 0.6) } else { level = max(1, level - watts / 52 * 100 / 30) }
            out.append(Sample(time: t, level: level.rounded(), plugged: plugged, charging: plugged && level < 100,
                              watts: watts, kind: asleep ? .wake : .reading))
            asleep = false
            t += 120
        }
        return out
    }
}
