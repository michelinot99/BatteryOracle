import Foundation

/// Probabilistic forecast of the Mac's power draw: one path per quantile level.
struct PowerForecast {
    enum Source: Equatable { case timestral(String), profile }
    var start: TimeInterval
    var step: TimeInterval
    var levels: [Double]          // quantile levels, ascending (0.01 … 0.99)
    var quantiles: [[Double]]     // [level][step] watts
    var source: Source
    var elapsed: Double
    var created = Date()

    var horizon: Int { quantiles.first?.count ?? 0 }
    func path(_ q: Double) -> [Double] {
        let i = levels.enumerated().min { abs($0.element - q) < abs($1.element - q) }!.offset
        return quantiles[i]
    }
}

// MARK: - Timestral engine

enum EngineError: LocalizedError {
    case missing, failed(String)
    var errorDescription: String? {
        switch self {
        case .missing: "Motore Timestral non installato"
        case .failed(let m): m
        }
    }
}

struct TimestralEngine {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BatteryOracle", isDirectory: true)
    static var python: URL { support.appendingPathComponent("engine/bin/python") }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    /// Bundled resource when running as an .app, the source tree when running with `swift run`.
    static func resource(_ name: String, _ subdir: String) -> URL? {
        if let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                     withExtension: (name as NSString).pathExtension) { return url }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        let url = dir.appendingPathComponent(subdir).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Runs the model in a short-lived, low-priority process: nothing stays resident between forecasts.
    static func forecast(bins: [Bin], horizon: Int, model: String) async throws -> PowerForecast {
        guard isInstalled, let script = resource("forecast.py", "engine") else { throw EngineError.missing }
        let request: [String: Any] = [
            "start": bins.first?.start ?? 0,
            "step": HistoryStore.step,
            "power": bins.map { $0.watts.map { ($0 * 100).rounded() / 100 } as Any? ?? NSNull() },
            "plugged": bins.map { $0.plugged.map { $0 ? 1 : 0 } as Any? ?? NSNull() },
            "horizon": horizon,
            "model": model,
        ]
        let input = try JSONSerialization.data(withJSONObject: request)
        let output = try await run(python, ["-I", script.path], stdin: input,
                                   env: ["HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false"])
        guard let json = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw EngineError.failed("Risposta del motore non valida")
        }
        if let err = json["error"] as? String { throw EngineError.failed(err) }
        guard let start = json["start"] as? Double, let levels = json["levels"] as? [Double],
              let q = json["quantiles"] as? [[Double]] else { throw EngineError.failed("Risposta incompleta") }
        return PowerForecast(start: start, step: json["step"] as? Double ?? HistoryStore.step, levels: levels,
                             quantiles: q, source: .timestral(json["model"] as? String ?? model),
                             elapsed: json["elapsed"] as? Double ?? 0)
    }

    static func run(_ exe: URL, _ args: [String], stdin: Data? = nil, env: [String: String] = [:],
                    timeout: TimeInterval = 120, onLine: (@Sendable (String) -> Void)? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.qualityOfService = .utility
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = inp
            let buffer = LockedData()
            out.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                buffer.append(chunk)
                if let onLine, let s = String(data: chunk, encoding: .utf8) {
                    s.split(separator: "\n").last.map { onLine(String($0)) }
                }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                if let onLine, let s = String(data: h.availableData, encoding: .utf8),
                   let line = s.split(separator: "\n").last { onLine(String(line)) }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                buffer.append(out.fileHandleForReading.readDataToEndOfFile())
                if proc.terminationStatus == 0 || !buffer.data.isEmpty { cont.resume(returning: buffer.data) }
                else { cont.resume(throwing: EngineError.failed("Il processo è terminato con codice \(proc.terminationStatus)")) }
            }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            if let stdin { inp.fileHandleForWriting.write(stdin) }
            try? inp.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: - Fallback: your own daily profile

enum ProfileForecaster {
    /// Seasonal baseline used until the Timestral engine is installed: for each future slot,
    /// the spread of what you drew at that time of day on similar days over the last two weeks.
    static func forecast(bins: [Bin], horizon: Int) -> PowerForecast? {
        guard let last = bins.last else { return nil }
        let levels = [0.01, 0.05] + stride(from: 0.1, through: 0.9, by: 0.05).map { ($0 * 100).rounded() / 100 } + [0.95, 0.99]
        let cal = Calendar.current
        func key(_ t: TimeInterval) -> (slot: Int, weekend: Bool) {
            let d = Date(timeIntervalSince1970: t)
            let c = cal.dateComponents([.hour, .minute], from: d)
            return (c.hour! * 4 + c.minute! / 15, cal.isDateInWeekend(d))
        }
        var bySlot: [Int: [Double]] = [:], bySlotAll: [Int: [Double]] = [:]
        for b in bins.suffix(96 * 14) {
            guard let w = b.watts else { continue }
            let k = key(b.start)
            bySlot[k.slot * 2 + (k.weekend ? 1 : 0), default: []].append(w)
            bySlotAll[k.slot, default: []].append(w)
        }
        let all = bins.compactMap(\.watts)
        guard all.count >= 8 else { return nil }
        let start = last.start + HistoryStore.step
        var q = Array(repeating: [Double](), count: levels.count)
        for i in 0..<horizon {
            let k = key(start + Double(i) * HistoryStore.step)
            var values = bySlot[k.slot * 2 + (k.weekend ? 1 : 0)] ?? []
            if values.count < 3 { values = bySlotAll[k.slot] ?? [] }
            if values.count < 3 { values = all }
            for (j, l) in levels.enumerated() { q[j].append(values.quantile(l)) }
        }
        return PowerForecast(start: start, step: HistoryStore.step, levels: levels, quantiles: q, source: .profile, elapsed: 0)
    }
}

// MARK: - From power to battery

/// What the forecast means for the battery if you stay on battery from now on.
struct Outlook {
    struct Point: Identifiable {
        let date: Date
        let median, p10, p90, p25, p75: Double
        var id: Date { date }
    }
    var points: [Point] = []
    var endOfDay: Date
    var levelAtEnd: Double = 0
    var rangeAtEnd: ClosedRange<Double> = 0...0
    var probability: Double = 1      // chance of being above the threshold at end of day
    var reachesThreshold: Date?      // median time the battery crosses the threshold
    var empty: Date?                 // median time the battery runs out
    var averageWatts: Double = 0     // forecast mean draw until end of day
    var start: Date                  // when the simulated day starts (now, or tomorrow morning)
    var isTomorrow = false

    enum Verdict { case fine, tight, charger }
    var verdict: Verdict { probability >= 0.85 ? .fine : probability >= 0.5 ? .tight : .charger }

    /// Simulates the level along every quantile path of power. High-draw paths are low-battery paths,
    /// so the p-th power quantile gives the (1-p)-th level quantile (assumes the paths move together,
    /// which makes the bands deliberately conservative).
    init(forecast f: PowerForecast, level: Double, fullChargeWh: Double, calibration: Double,
         threshold: Double, endOfDay: Date, now: Date = Date(), tomorrowFrom: Date? = nil) {
        self.endOfDay = endOfDay
        let now = tomorrowFrom ?? now
        start = now
        isTomorrow = tomorrowFrom != nil
        let pctPerWattStep = f.step / 3600 / fullChargeWh * 100 * calibration
        let firstStep = max(0, Int(((now.timeIntervalSince1970 - f.start) / f.step).rounded(.down)))
        guard firstStep < f.horizon else { return }
        let steps = firstStep..<f.horizon

        var levelPaths: [[Double]] = []
        for path in f.quantiles {
            var l = level, out: [Double] = []
            for i in steps { l -= path[i] * pctPerWattStep; out.append(l) }
            levelPaths.append(out)
        }
        func idx(_ q: Double) -> Int { f.levels.enumerated().min { abs($0.element - q) < abs($1.element - q) }!.offset }
        let (i50, i10, i90, i25, i75) = (idx(0.5), idx(0.1), idx(0.9), idx(0.25), idx(0.75))

        points = [Point(date: now, median: level, p10: level, p90: level, p25: level, p75: level)]
        for (k, i) in steps.enumerated() {
            let date = Date(timeIntervalSince1970: f.start + Double(i + 1) * f.step)
            func c(_ j: Int) -> Double { max(0, levelPaths[j][k]) }
            points.append(Point(date: date, median: c(i50), p10: c(i90), p90: c(i10), p25: c(i75), p75: c(i25)))
        }

        let endK = points.dropFirst().firstIndex { $0.date >= endOfDay }.map { $0 - 1 } ?? (points.count - 2)
        let ends = levelPaths.map { $0[max(0, min(endK, $0.count - 1))] }
        levelAtEnd = max(0, ends[i50])
        rangeAtEnd = max(0, ends[i90])...max(0, ends[i10])
        // P(level_end > threshold) = P(power quantile below the one that lands exactly on the threshold).
        if ends.last! >= threshold { probability = 0.99 }
        else if ends.first! < threshold { probability = 0.01 }
        else {
            probability = 0.01
            for j in 1..<ends.count where ends[j] < threshold {
                let t = (ends[j - 1] - threshold) / max(1e-9, ends[j - 1] - ends[j])
                probability = f.levels[j - 1] + t * (f.levels[j] - f.levels[j - 1])
                break
            }
        }
        reachesThreshold = points.first { $0.median < threshold }?.date
        empty = points.first { $0.median <= 0.5 }?.date
        let toEnd = f.quantiles[i50][steps].prefix(max(1, endK + 1))
        averageWatts = toEnd.reduce(0, +) / Double(toEnd.count)
    }
}
