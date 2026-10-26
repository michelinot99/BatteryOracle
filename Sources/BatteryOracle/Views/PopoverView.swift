import Charts
import SwiftUI

struct PopoverView: View {
    @ObservedObject var m: AppModel
    @StateObject private var ui = PopoverState()

    enum Tab: String, CaseIterable { case forecast = "Previsione", habits = "Abitudini" }

    /// A MenuBarExtra window keeps the size it opened with, so both tabs share one fixed height.
    static let tabHeight: CGFloat = 368

    /// View-local state lives here: the Command Line Tools SDK ships SwiftUI's `@State` as a macro without its plugin.
    final class PopoverState: ObservableObject {
        @Published var tab = CommandLine.arguments.contains("--habits") ? Tab.habits : Tab.forecast
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if m.battery == nil {
                noBattery
            } else if let o = m.outlook {
                VerdictCard(o: o, m: m)
                CapsuleTabs(selection: $ui.tab, tint: o.verdict.color)
                Group {
                    if ui.tab == .forecast { ForecastChart(o: o, m: m) } else { HabitsView(m: m) }
                }
                .frame(height: Self.tabHeight, alignment: .top)
            } else {
                learning
            }
            footer
        }
        .padding(16)
        .frame(width: 372)
        .animation(.smooth, value: ui.tab)
    }

    private var header: some View {
        HStack(spacing: 14) {
            LevelRing(level: m.battery?.level ?? 0, charging: m.battery?.charging ?? false,
                      tint: m.batteryTint.color.map(Color.init(nsColor:)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Batteria").font(.headline)
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
                if let b = m.battery {
                    Text("Salute \(Int(b.health * 100))% · \(b.cycles) cicli\(b.temperature.map { String(format: " · %.0f °C", $0) } ?? "")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var statusLine: String {
        guard let b = m.battery else { return "—" }
        let w = b.systemWatts.map { String(format: "%.1f W", $0) }
        if b.charging {
            return ["In carica", b.minutesToFull.map { "piena alle \(Date().addingTimeInterval(Double($0) * 60).hm)" }, w]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if b.plugged { return ["Alimentatore collegato", b.adapterWatts.map { "\($0) W" }].compactMap { $0 }.joined(separator: " · ") }
        return ["A batteria", w].compactMap { $0 }.joined(separator: " · ")
    }

    private var learning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sto imparando le tue abitudini", systemImage: "brain.head.profile").font(.headline)
            Text("BatteryOracle registra quanto consuma il Mac, minuto per minuto. Dopo un paio d'ore di utilizzo arriva la prima previsione; dopo qualche giorno diventa precisa.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ProgressView(value: m.learningProgress) { EmptyView() } currentValueLabel: {
                Text("Storico: \(Int(m.learningProgress * 100))% dei 3 giorni consigliati").font(.caption2)
            }
            if m.isForecasting { ProgressView().controlSize(.small) }
        }
        .card()
    }

    private var noBattery: some View {
        Label("Questo Mac non ha una batteria interna.", systemImage: "desktopcomputer").card()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Group {
                if m.isForecasting {
                    ProgressView().controlSize(.mini)
                    Text("Timestral sta calcolando…")
                } else if let f = m.forecast {
                    Image(systemName: f.source == .profile ? "chart.bar.xaxis" : "sparkles")
                    Text(sourceLine(f))
                } else if let e = m.engineError {
                    Image(systemName: "exclamationmark.triangle")
                    Text(e).lineLimit(1)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button { m.toggleLowPowerMode() } label: {
                Image(systemName: m.lowPowerMode ? "leaf.fill" : "leaf").frame(width: 22, height: 22)
                    .foregroundStyle(m.lowPowerMode ? Color.yellow : Color.secondary)
            }
            .help(m.lowPowerMode ? "Disattiva la modalità risparmio energetico" : "Attiva la modalità risparmio energetico")
            Button { m.forecastNow() } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
                .help("Ricalcola la previsione").disabled(m.isForecasting)
            Button { SettingsWindow.show(m) } label: { Image(systemName: "gearshape").frame(width: 22, height: 22) }
                .help("Impostazioni")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func sourceLine(_ f: PowerForecast) -> String {
        let mins = Int(Date().timeIntervalSince(f.created) / 60)
        let age = mins < 1 ? "adesso" : mins < 60 ? "\(mins) min fa" : f.created.hm
        switch f.source {
        case .timestral(let name): return "Mistral \(name.replacingOccurrences(of: "-", with: " ")) · \(age)"
        case .profile: return "Profilo statistico · installa Timestral nelle impostazioni"
        }
    }
}

// MARK: - Verdict

struct VerdictCard: View {
    let o: Outlook
    @ObservedObject var m: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: o.verdict.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(o.verdict.color.gradient)
                    .symbolEffect(.bounce, value: o.verdict)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.verdict.title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                ProbabilityDial(p: o.probability, color: o.verdict.color)
            }
            HStack(spacing: 10) {
                Stat(title: "Alle \(o.endOfDay.hm)", value: "\(Int(o.levelAtEnd))%", symbol: "flag.checkered",
                     detail: "\(Int(o.rangeAtEnd.lowerBound))–\(Int(o.rangeAtEnd.upperBound))%")
                Stat(title: o.reachesThreshold == nil ? "Autonomia" : "Sotto \(Int(m.threshold))%",
                     value: autonomy, symbol: "hourglass")
                Stat(title: "Media", value: String(format: "%.1f W", o.averageWatts), symbol: "bolt")
            }
        }
        .card(tint: o.verdict.color)
    }

    private var subtitle: String {
        let plugged = m.battery?.plugged == true
        let lead = o.isTomorrow ? "Domani, partendo carico alle \(o.start.hm): " : plugged ? "Se stacchi ora, " : ""
        let p = Int((o.probability * 100).rounded())
        switch o.verdict {
        case .fine: return "\(lead)\(p)% di probabilità di arrivare alle \(o.endOfDay.hm) sopra il \(Int(m.threshold))%."
        case .tight: return "\(lead)\(p)% di probabilità: dipende da quanto spingerai il Mac."
        case .charger:
            if let t = o.reachesThreshold { return "\(lead)scendi sotto il \(Int(m.threshold))% verso le \(t.hm)." }
            return "\(lead)solo \(p)% di probabilità di farcela."
        }
    }

    private var autonomy: String {
        if let t = o.reachesThreshold { return t.hm }
        guard let last = o.points.last else { return "—" }
        return "oltre le \(last.date.hm)"
    }
}

struct ProbabilityDial: View {
    var p: Double
    var color: Color
    var body: some View {
        ZStack {
            Group {
                Circle().trim(from: 0, to: 0.75).stroke(.quaternary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                Circle().trim(from: 0, to: 0.75 * p).stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .animation(.smooth, value: p)
            }
            .rotationEffect(.degrees(135))
            Text("\(Int((p * 100).rounded()))%").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
            Text("prob.").font(.system(size: 8)).foregroundStyle(.secondary).offset(y: 17)
        }
        .frame(width: 42, height: 42)
        .help("Probabilità di arrivare a fine giornata sopra la soglia")
    }
}

// MARK: - Forecast chart

struct ForecastChart: View {
    let o: Outlook
    @ObservedObject var m: AppModel
    @StateObject private var hoverState = HoverState()
    final class HoverState: ObservableObject { @Published var date: Date? }
    private var hover: Date? { hoverState.date }

    var body: some View {
        let history = o.isTomorrow ? [] : m.recentLevels
        let start = o.isTomorrow ? o.start.addingTimeInterval(-1800) : history.first?.date ?? Date().addingTimeInterval(-12 * 3600)
        let end = max(o.endOfDay.addingTimeInterval(3 * 3600), o.start.addingTimeInterval(12 * 3600))
        let points = o.points.filter { $0.date <= end }
        let accent = o.verdict.color

        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(text: o.isTomorrow ? "Domani" : "Prossime ore",
                         trailing: o.isTomorrow ? "parti al 100% alle \(o.start.hm)" : m.battery?.plugged == true ? "ipotesi: stacchi ora" : "fascia 80% e 50%")
            Chart {
                RectangleMark(xStart: .value("", start), xEnd: .value("", end), yStart: .value("", 0), yEnd: .value("", m.threshold))
                    .foregroundStyle(.red.opacity(0.07))
                ForEach(history, id: \.date) { p in
                    AreaMark(x: .value("Ora", p.date), y: .value("Livello", p.level), series: .value("s", "storico"))
                        .foregroundStyle(LinearGradient(colors: [.accentColor.opacity(0.28), .accentColor.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Ora", p.date), y: .value("Livello", p.level), series: .value("s", "storico"))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                ForEach(points) { p in
                    AreaMark(x: .value("Ora", p.date), yStart: .value("", p.p10), yEnd: .value("", p.p90), series: .value("s", "80"))
                        .foregroundStyle(accent.opacity(0.13))
                    AreaMark(x: .value("Ora", p.date), yStart: .value("", p.p25), yEnd: .value("", p.p75), series: .value("s", "50"))
                        .foregroundStyle(accent.opacity(0.22))
                    LineMark(x: .value("Ora", p.date), y: .value("Livello", p.median), series: .value("s", "previsione"))
                        .foregroundStyle(accent)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]))
                }
                RuleMark(x: .value("Adesso", o.start))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text(o.isTomorrow ? "sveglia" : "ora").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                RuleMark(x: .value("Fine giornata", o.endOfDay))
                    .foregroundStyle(accent.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Image(systemName: "flag.checkered").font(.system(size: 9)).foregroundStyle(accent)
                    }
                if let h = hover, let p = points.min(by: { abs($0.date.timeIntervalSince(h)) < abs($1.date.timeIntervalSince(h)) }) {
                    PointMark(x: .value("Ora", p.date), y: .value("Livello", p.median))
                        .foregroundStyle(accent)
                        .annotation(position: .top, spacing: 4) {
                            VStack(spacing: 0) {
                                Text("\(p.date.hm) · \(Int(p.median))%").font(.caption2.weight(.semibold))
                                Text("\(Int(p.p10))–\(Int(p.p90))%").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                        }
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.system(size: 9)) }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.hour(), centered: false).font(.system(size: 9))
                }
            }
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let loc) = phase, let d: Date = proxy.value(atX: loc.x), d > o.start { hoverState.date = d }
                        else { hoverState.date = nil }
                    }
            }
            .frame(minHeight: 150, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }
}
