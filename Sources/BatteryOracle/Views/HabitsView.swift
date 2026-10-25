import Charts
import SwiftUI

struct HabitsView: View {
    @ObservedObject var m: AppModel

    var body: some View {
        let hourly = m.bins.hourlyProfile()
        let daily = m.bins.dailyUsage()
        let nowHour = Calendar.current.component(.hour, from: Date())
        let active = daily.filter { $0.total > 1 }
        let avgDay = active.isEmpty ? 0 : active.map(\.total).reduce(0, +) / Double(active.count)
        let peak = hourly.max { $0.watts < $1.watts }
        let awakeWatts = hourly.map(\.watts).filter { $0 > 1 }
        let typicalW = awakeWatts.isEmpty ? 0 : awakeWatts.reduce(0, +) / Double(awakeWatts.count)
        let wh = m.battery?.fullChargeWh ?? 50

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Stat(title: "Giornata tipo", value: String(format: "%.0f Wh", avgDay), symbol: "calendar")
                Stat(title: "Ora di punta", value: peak.map { "\($0.hour):00–\($0.hour + 1):00" } ?? "—", symbol: "flame")
                Stat(title: "Autonomia", value: typicalW > 0 ? hours(wh / typicalW * m.calibration) : "—", symbol: "battery.75percent")
            }

            SectionTitle(text: "Consumo medio per ora", trailing: "ultimi 14 giorni")
            Chart(hourly) { h in
                BarMark(x: .value("Ora", h.hour), y: .value("W", h.watts), width: .fixed(9))
                    .foregroundStyle(h.hour == nowHour ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.green.opacity(0.75).gradient))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) { AxisValueLabel().font(.system(size: 9)) } }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0) W").font(.system(size: 9)) }
                }
            }
            .frame(height: 80)

            SectionTitle(text: "Energia al giorno", trailing: "ultimi 10 giorni")
            Chart {
                ForEach(daily) { d in
                    BarMark(x: .value("Giorno", d.day, unit: .day), y: .value("Wh", d.batteryWh))
                        .foregroundStyle(by: .value("Fonte", "A batteria"))
                    BarMark(x: .value("Giorno", d.day, unit: .day), y: .value("Wh", d.adapterWh))
                        .foregroundStyle(by: .value("Fonte", "Alimentatore"))
                }
                if avgDay > 0 {
                    RuleMark(y: .value("Media", avgDay)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartForegroundStyleScale(["A batteria": Color.green.gradient, "Alimentatore": Color.blue.gradient])
            .chartLegend(position: .bottom, spacing: 6) {
                HStack(spacing: 12) {
                    legend("A batteria", .green)
                    legend("Alimentatore", .blue)
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 9)) } }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0) Wh").font(.system(size: 9)) }
                }
            }
            .frame(height: 110)

            Text(calibrationNote).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private var calibrationNote: String {
        let wh = Int(m.battery?.fullChargeWh ?? 0)
        let c = Int(((m.calibration - 1) * 100).rounded())
        return "Batteria da circa \(wh) Wh a piena carica. Correzione appresa dalle tue scariche reali: \(c >= 0 ? "+" : "")\(c)%."
    }

    private func legend(_ s: String, _ c: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(s).font(.caption2).foregroundStyle(.secondary) }
    }

    private func hours(_ h: Double) -> String {
        let mins = Int((h * 60).rounded())
        return "\(mins / 60) h \(String(format: "%02d", mins % 60)) m"
    }
}
