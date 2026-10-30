import SwiftUI

/// System surfaces follow iOS appearance and accessibility settings.
enum Tone {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let sunken = Color(uiColor: .tertiarySystemFill)
    static let ink = Color.primary
    static let ink2 = Color.secondary
    static let ink3 = Color(uiColor: .tertiaryLabel)
    static let hairline = Color(uiColor: .separator)
    static let moss = Color.accentColor
    static let mossSoft = Color.accentColor.opacity(0.12)
    static let onMoss = Color.white
    static let signal = Color(uiColor: .systemOrange)
    static let heart = Color(uiColor: .systemRed)
}

extension Font {
    /// Condensed figures for numbers that should read at a glance.
    static func figure(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
    static let eyebrow = Font.system(size: 11, weight: .semibold).width(.expanded)
}

struct Eyebrow: View {
    let text: String
    var color: Color = Tone.ink2
    init(_ text: String, color: Color = Tone.ink2) { self.text = text; self.color = color }
    var body: some View {
        Text(L(text).uppercased()).font(.eyebrow).tracking(0.9).foregroundStyle(color)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Tone.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// Subtle press feedback for every tappable surface.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    var busy = false
    let action: () -> Void
    var body: some View {
        if #available(iOS 26.0, *) {
            if prominent { button.buttonStyle(.glassProminent).controlSize(.large) }
            else { button.buttonStyle(.glass).controlSize(.large) }
        } else {
            if prominent { button.buttonStyle(.borderedProminent).controlSize(.large) }
            else { button.buttonStyle(.bordered).controlSize(.large) }
        }
    }
    private var button: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if busy { ProgressView().controlSize(.small).tint(prominent ? Tone.onMoss : Tone.ink) }
                else if let symbol { Image(systemName: symbol).font(.subheadline.weight(.semibold)) }
                Text(L(title)).font(.subheadline.weight(.semibold))
            }
        }
        .buttonBorderShape(.capsule)
    }
}

/// The app mark, drawn from the icon's geometry (1024-point grid, 28° tilt).
struct PebbleMark: View {
    var size: CGFloat = 64
    var color: Color = Tone.moss
    var cutout: Color = Tone.surface
    var glowing = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let s = size / 1024
        ZStack {
            Capsule().strokeBorder(color, lineWidth: 48 * s).frame(width: 392 * s, height: 682 * s)
            Capsule().fill(color).frame(width: 180 * s, height: 348 * s)
            Circle().fill(glowing ? Tone.onMoss : cutout).frame(width: 28 * s, height: 28 * s).offset(y: -102 * s)
                .opacity(glowing && breathe ? 0.35 : 1)
        }
        .rotationEffect(.degrees(28))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { if glowing && !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { breathe = true } } }
        .onChange(of: glowing) { _, on in
            if on && !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { breathe = true } }
            else { withAnimation(.easeOut(duration: 0.2)) { breathe = false } }
        }
    }
}

/// Progress toward the daily goal with milestone ticks.
struct MilestoneTrack: View {
    let progress: Double
    let ticks: [Double]
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width, clamped = min(1, max(0, progress))
            ZStack(alignment: .leading) {
                Capsule().fill(Tone.sunken)
                Capsule().fill(Tone.moss).frame(width: max(clamped > 0 ? 10 : 0, width * clamped))
                ForEach(ticks.filter { $0 > 0 && $0 < 1 }, id: \.self) { tick in
                    Circle().fill(tick <= clamped ? Tone.onMoss.opacity(0.9) : Tone.ink3)
                        .frame(width: 4, height: 4).offset(x: width * tick - 2)
                }
            }
        }
        .frame(height: 10)
        .animation(.spring(duration: 0.5, bounce: 0.1), value: progress)
        .accessibilityElement().accessibilityLabel(L("Goal progress")).accessibilityValue(L("%@ percent", String(describing: Int(min(1, progress) * 100))))
    }
}

/// A person's usual range with the recent value marked on it.
struct RangeBar: View {
    let low: Double, high: Double, value: Double
    var outside: Bool? = nil
    var body: some View {
        GeometryReader { geo in
            let span = max(high - low, 0.0001)
            let lower = min(low, value) - span * 0.6, upper = max(high, value) + span * 0.6
            let x: (Double) -> CGFloat = { CGFloat(($0 - lower) / (upper - lower)) * geo.size.width }
            let outside = self.outside ?? (value < low || value > high)
            ZStack(alignment: .leading) {
                Capsule().fill(Tone.sunken).frame(height: 4).frame(maxHeight: .infinity)
                Capsule().fill(Tone.mossSoft).frame(width: max(6, x(high) - x(low)), height: 10).offset(x: x(low)).frame(maxHeight: .infinity)
                Circle().fill(outside ? Tone.signal : Tone.moss).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Tone.surface, lineWidth: 2))
                    .offset(x: x(value) - 6).frame(maxHeight: .infinity)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// A vibration pattern drawn as beats on a short timeline.
struct PatternGlyph: View {
    let pattern: BuzzPattern
    var color: Color = Tone.ink
    var body: some View {
        let beats = pattern.beats, total = (beats.last ?? 0) + 1
        GeometryReader { geo in
            ForEach(Array(beats.enumerated()), id: \.offset) { _, beat in
                Capsule().fill(color)
                    .frame(width: max(4, geo.size.width / CGFloat(total) * 0.7), height: geo.size.height)
                    .offset(x: geo.size.width * CGFloat(beat / total))
            }
        }
        .frame(width: 54, height: 10)
        .accessibilityLabel(L(pattern.title))
    }
}

extension View {
    func screenBackground() -> some View { background(Tone.canvas.ignoresSafeArea()) }
}

enum Format {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return L("just now") }
        if seconds < 3600 { return L("%@ min ago", String(describing: Int(seconds / 60))) }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
    static func clock(hours: Double) -> String {
        var minutes = Int((hours * 60).rounded()) % 1440
        if minutes < 0 { minutes += 1440 }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
    /// Whole number with a typographic sign: "+12", "−4", "0".
    static func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : rounded < 0 ? "−\(-rounded)" : "0"
    }
    static func value(_ value: Double, _ kind: MetricKind) -> String {
        kind == .sleepMidpoint ? clock(hours: value) : value.formatted(.number.precision(.fractionLength(kind.decimals)))
    }
}
