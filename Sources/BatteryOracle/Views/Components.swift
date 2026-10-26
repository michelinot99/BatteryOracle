import SwiftUI

extension Outlook.Verdict {
    var color: Color {
        switch self {
        case .fine: .green
        case .tight: .orange
        case .charger: .red
        }
    }
    var symbol: String {
        switch self {
        case .fine: "checkmark.seal.fill"
        case .tight: "exclamationmark.triangle.fill"
        case .charger: "powerplug.fill"
        }
    }
    var title: String {
        switch self {
        case .fine: "Arrivi a fine giornata"
        case .tight: "Ce la fai, ma al limite"
        case .charger: "Porta il caricabatterie"
        }
    }
}

func levelColor(_ level: Double) -> Color {
    level <= 10 ? .red : level <= 25 ? .orange : .green
}

extension Date {
    var hm: String { formatted(date: .omitted, time: .shortened) }
}

/// Liquid Glass on macOS 26+, a soft material card before that.
struct Card: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26, *) {
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(tint.map { .regular.tint($0.opacity(0.18)) } ?? .regular, in: shape)
        } else {
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((tint ?? .primary).opacity(0.08), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08)))
        }
    }
}

extension View {
    func card(tint: Color? = nil) -> some View { modifier(Card(tint: tint)) }
}

struct LevelRing: View {
    var level: Double
    var charging: Bool
    var tint: Color?
    var body: some View {
        let color = tint ?? levelColor(level)
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 7)
            Circle()
                .trim(from: 0, to: level / 100)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.65), color], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * level / 100)),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: level)
            VStack(spacing: -2) {
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.yellow)
                        .symbolEffect(.pulse)
                }
                Text("\(Int(level))").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(value: level))
                Text("%").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 62, height: 62)
    }
}

struct Stat: View {
    var title: String
    var value: String
    var symbol: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.callout.weight(.semibold)).monospacedDigit()
                if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionTitle: View {
    var text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Spacer()
            if let trailing { Text(trailing).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}

/// Pill-shaped tab switcher drawn entirely in SwiftUI.
struct CapsuleTabs<T: Hashable & CaseIterable & RawRepresentable>: View where T.RawValue == String, T.AllCases: RandomAccessCollection {
    @Binding var selection: T
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(T.allCases), id: \.self) { tab in
                let on = tab == selection
                Button { withAnimation(.snappy) { selection = tab } } label: {
                    Text(tab.rawValue)
                        .font(.callout.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if on { Capsule().fill(tint.opacity(0.22)).overlay(Capsule().strokeBorder(tint.opacity(0.35))) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(on ? .primary : .secondary)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}
