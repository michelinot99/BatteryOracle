import SwiftUI

struct SettingsView: View {
    @ObservedObject var m: AppModel
    var close: () -> Void

    static let models = [("mistralai/Timestral-5M", "5M · istantaneo"),
                         ("mistralai/Timestral-28M", "28M · bilanciato"),
                         ("mistralai/Timestral-123M", "123M · più preciso")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: close) { Label("Indietro", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                Text("Impostazioni").font(.headline)
                Spacer()
                Color.clear.frame(width: 60, height: 1)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Giornata")
                row("Fine giornata", "flag.checkered") {
                    DatePicker("", selection: minutes($m.endOfDayMinutes), displayedComponents: .hourAndMinute).labelsHidden()
                }
                row("Soglia minima: \(Int(m.threshold))%", "battery.25percent") {
                    Slider(value: $m.threshold, in: 5...30, step: 5).frame(width: 130)
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Avvisi")
                Toggle(isOn: $m.morningAlert) {
                    HStack {
                        Label("Avviso del mattino", systemImage: "sunrise")
                        Spacer()
                        DatePicker("", selection: minutes($m.morningMinutes), displayedComponents: .hourAndMinute)
                            .labelsHidden().disabled(!m.morningAlert)
                    }
                }
                Toggle(isOn: $m.liveAlert) { Label("Avvisami se non ci arrivo", systemImage: "bell.badge") }
                if !m.canLaunchAtLogin {
                    Text("Le notifiche funzionano quando l'app è installata come BatteryOracle.app.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            .card()

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Motore di previsione")
                if m.engineInstalled {
                    Picker(selection: $m.model) {
                        ForEach(Self.models, id: \.0) { Text($0.1).tag($0.0) }
                    } label: { Label("Mistral Timestral", systemImage: "sparkles") }
                    Text("Gira in locale sulla CPU: i tuoi dati non lasciano il Mac.")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else if let log = m.installLog {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Installo Timestral…").font(.callout)
                            Text(log).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                } else {
                    Text("Ora uso il tuo profilo orario medio. Installa Mistral Timestral (PyTorch, circa 1 GB) per previsioni probabilistiche vere.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { m.installEngine() } label: { Label("Installa Timestral", systemImage: "arrow.down.circle") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                if let e = m.engineError {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange).lineLimit(3)
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $m.showPercent) { Label("Percentuale nella barra dei menu", systemImage: "percent") }
                if m.canLaunchAtLogin {
                    Toggle(isOn: Binding(get: { m.launchAtLogin }, set: { m.launchAtLogin = $0 })) {
                        Label("Apri al login", systemImage: "power")
                    }
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            .card()

            HStack {
                Text("BatteryOracle · dati in ~/Library/Application Support").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
    }

    private func row<C: View>(_ title: String, _ symbol: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack { Label(title, systemImage: symbol).monospacedDigit(); Spacer(); control() }
    }

    private func minutes(_ b: Binding<Int>) -> Binding<Date> {
        Binding(
            // date(bySettingHour:) rather than midnight + minutes, which drifts by an hour on DST days.
            get: { Calendar.current.date(bySettingHour: b.wrappedValue / 60, minute: b.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                b.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}
