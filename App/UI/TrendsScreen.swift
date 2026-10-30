import SwiftUI
import Charts

private enum TrendTopic: Hashable, CaseIterable, Identifiable {
    case metric(MetricKind), training
    static var allCases: [TrendTopic] { [.metric(.steps), .metric(.sleepHours), .metric(.restingPulse), .metric(.hrvSDNN), .metric(.sleepMidpoint), .training] }
    var id: String { title }
    var title: String { if case .metric(let kind) = self { return kind.short }; return L("Training") }
}

struct TrendsScreen: View {
    @EnvironmentObject private var library: AppStore
    @State private var topic = TrendTopic.metric(.steps)
    @State private var weeks = 4
    @State private var methods = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TopicBar(topic: $topic)
                    switch topic {
                    case .metric(let kind): MetricTrendView(kind: kind, weeks: $weeks)
                    case .training: TrainingTrendView()
                    }
                    Button { methods = true } label: {
                        Label(L("How these are calculated"), systemImage: "book.closed").font(.footnote.weight(.medium)).foregroundStyle(Tone.ink2)
                    }.buttonStyle(PressStyle()).padding(.horizontal, 4).padding(.top, 4)
                }
                .padding(.horizontal, 16).padding(.bottom, 28)
            }
            .screenBackground()
            .navigationTitle(L("Trends"))
            .sheet(isPresented: $methods) { NavigationStack { MethodsScreen() } }
        }
    }
}

private struct TopicBar: View {
    @Binding var topic: TrendTopic
    @Namespace private var selection
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TrendTopic.allCases) { item in
                    Button { withAnimation(.snappy(duration: 0.25)) { topic = item } } label: {
                        Text(L(item.title)).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 34)
                            .foregroundStyle(topic == item ? Tone.onMoss : Tone.ink)
                            .background {
                                if topic == item { Capsule().fill(Tone.moss).matchedGeometryEffect(id: "chip", in: selection) }
                                else { Capsule().fill(Tone.surface) }
                            }
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityAddTraits(topic == item ? .isSelected : [])
                }
            }
        }
        .sensoryFeedback(.selection, trigger: topic)
    }
}

private struct MetricTrendView: View {
    @EnvironmentObject private var library: AppStore
    let kind: MetricKind
    @Binding var weeks: Int
    var body: some View {
        let points = library.points(kind)
        let start = Calendar.current.date(byAdding: .day, value: -weeks * 7, to: Calendar.current.startOfDay(for: Date()))!
        let visible = points.filter { $0.date >= start }
        let trend = FitnessMath.trend(points)
        let signal = kind == .sleepMidpoint ? nil : FitnessMath.signal(kind, points)
        Card {
            Eyebrow(L(kind.title))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(trend.recent.map { Format.value($0, kind) } ?? "—").font(.figure(56)).monospacedDigit()
                Text(L(kind == .sleepMidpoint ? L("avg midpoint") : kind.unit)).font(.subheadline).foregroundStyle(Tone.ink2)
                Spacer()
                if let delta = trend.delta, kind != .sleepMidpoint { DeltaChip(delta: delta, kind: kind) }
            }.padding(.top, 6)
            Text(L("7-day average · %@ of 7 days", String(describing: trend.recentDays))).font(.caption).foregroundStyle(Tone.ink3)
            if visible.isEmpty {
                Text(L(emptyMessage)).font(.subheadline).foregroundStyle(Tone.ink2).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                MetricChart(kind: kind, points: visible, signal: signal).frame(height: 190).padding(.top, 16)
            }
            Picker(L("Range"), selection: $weeks) { Text(L("4 weeks")).tag(4); Text(L("12 weeks")).tag(12) }
                .pickerStyle(.segmented).padding(.top, 14)
        }
        if kind == .sleepMidpoint, let sd = FitnessMath.regularity(points) {
            Card {
                Eyebrow(L("Regularity"))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("±\(Int(sd.rounded()))").font(.figure(40)).monospacedDigit()
                    Text(L("min night to night")).font(.subheadline).foregroundStyle(Tone.ink2)
                }.padding(.top, 6)
                Text(L("Variation of your sleep midpoint over two weeks. Steadier timing supports your body clock.")).font(.footnote).foregroundStyle(Tone.ink2).padding(.top, 6)
                if let jetlag = FitnessMath.socialJetlag(points) {
                    Divider().padding(.vertical, 12)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L(Format.clock(hours: jetlag))).font(.figure(28)).monospacedDigit()
                        Text(L("social jetlag")).font(.subheadline).foregroundStyle(Tone.ink2)
                    }
                    Text(L("Gap between your weekend and weekday sleep midpoints (Wittmann et al., 2006). Smaller is gentler on your body clock.")).font(.caption).foregroundStyle(Tone.ink3).padding(.top, 6)
                }
            }
        }
        if let signal {
            Card {
                Eyebrow(L("Your usual range"))
                RangeBar(low: signal.low, high: signal.high, value: signal.recent, outside: signal.shown(kind.decimals) != .within).padding(.top, 14)
                HStack {
                    Text("\(Format.value(signal.low, kind))–\(Format.value(signal.high, kind)) \(L(kind.unit))").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(L("%@ days of history", String(describing: signal.baselineDays))).font(.caption).foregroundStyle(Tone.ink3)
                }.padding(.top, 10)
                Text(L(note)).font(.footnote).foregroundStyle(Tone.ink2).padding(.top, 8)
            }
        }
        SourceCard(kind: kind)
    }
    private var emptyMessage: String {
        kind == .steps ? L("Daily steps appear as you sync your band or import Apple Health.") : L("Import Apple Health in the Band tab to see this trend.")
    }
    private var note: String {
        switch kind {
        case .hrvSDNN: return L("HRV is compared on a log scale with a ±0.5 SD band, the smallest change considered meaningful in daily HRV monitoring. Apple Health stores SDNN, so values aren’t comparable with RMSSD-based apps.")
        case .restingPulse: return L("A resting heart rate above your usual range for several days often follows hard training, poor sleep, alcohol or illness.")
        case .sleepHours: return L("Adults are advised to sleep at least 7 hours regularly (AASM/SRS consensus).")
        case .steps: return L("More daily steps are linked to lower mortality, with benefits levelling off around 8,000–10,000 steps.")
        case .sleepMidpoint: return ""
        }
    }
}

private struct DeltaChip: View {
    let delta: Double
    let kind: MetricKind
    var body: some View {
        let favourable = kind.higherIsBetter.map { $0 == (delta >= 0) } ?? true
        let text = (delta >= 0 ? "+" : "−") + Format.value(abs(delta), kind)
        Text(L(text)).font(.caption.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 8).frame(height: 24)
            .foregroundStyle(favourable ? Tone.moss : Tone.signal)
            .background(favourable ? Tone.mossSoft : Tone.signal.opacity(0.12), in: Capsule())
            .accessibilityLabel(L("Change versus the previous four weeks: %@", String(describing: text)))
    }
}

private struct MetricChart: View {
    let kind: MetricKind
    let points: [DailyMetric]
    let signal: BodySignal?
    var body: some View {
        Chart {
            if let signal {
                RectangleMark(xStart: .value(L("Start"), points.first!.date), xEnd: .value(L("End"), points.last!.date),
                              yStart: .value(L("Low"), signal.low), yEnd: .value(L("High"), signal.high))
                    .foregroundStyle(Tone.mossSoft.opacity(0.7))
            }
            ForEach(points) { point in
                if kind == .steps || kind == .sleepHours {
                    BarMark(x: .value(L("Day"), point.date, unit: .day), y: .value(kind.unit, point.value), width: .ratio(0.62))
                        .foregroundStyle(Tone.moss.opacity(0.55)).clipShape(Capsule())
                } else {
                    PointMark(x: .value(L("Day"), point.date, unit: .day), y: .value(kind.unit, point.value))
                        .foregroundStyle(Tone.moss).symbolSize(22)
                }
            }
            ForEach(rolling) { point in
                LineMark(x: .value(L("Day"), point.date, unit: .day), y: .value("7-day", point.value))
                    .foregroundStyle(Tone.ink).lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round)).interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: .automatic(includesZero: kind == .steps || kind == .sleepHours))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Tone.hairline)
                AxisValueLabel { if let v = value.as(Double.self) { Text(kind == .sleepMidpoint ? Format.clock(hours: v) : v.formatted(.number.notation(.compactName))).font(.caption2).foregroundStyle(Tone.ink3) } }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption2).foregroundStyle(Tone.ink3)
            }
        }
        .accessibilityLabel(L("%@ daily values with seven-day average", String(describing: kind.title)))
    }
    /// Seven-day rolling mean drawn only where at least four days exist.
    private struct Rolling: Identifiable { let date: Date; let value: Double; var id: Date { date } }
    private var rolling: [Rolling] {
        points.compactMap { point in
            let window = points.filter { $0.date <= point.date && $0.date > point.date.addingTimeInterval(-7 * 86400) }
            guard window.count >= 4, let mean = FitnessMath.mean(window.map(\.value)) else { return nil }
            return Rolling(date: point.date, value: mean)
        }
    }
}

private struct SourceCard: View {
    @EnvironmentObject private var library: AppStore
    let kind: MetricKind
    var body: some View {
        let options = library.sourceOptions(kind)
        if options.count > 1 {
            Card(padding: 14) {
                HStack {
                    Eyebrow(L("Source"))
                    Spacer()
                    Menu {
                        ForEach(options, id: \.id) { option in
                            Button(option.name) { library.change { $0.sources[kind.rawValue] = option.id } }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(L(library.points(kind).first?.sourceName ?? L("Choose"))).font(.subheadline.weight(.medium)).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }.foregroundStyle(Tone.moss)
                    }
                }
            }
        }
    }
}

private struct TrainingTrendView: View {
    @EnvironmentObject private var library: AppStore
    var body: some View {
        let states = FitnessMath.training(library.data.workouts, days: 120)
        let recent = Array(states.suffix(56).drop { $0.fitness < 0.5 })
        Card {
            Eyebrow(L("Fitness · fatigue · form"))
            if let today = states.last, library.data.workouts.contains(where: { $0.load != nil }) {
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    stat(L("Form"), today.form, signed: true)
                    stat(L("Fitness"), today.fitness)
                    stat(L("Fatigue"), today.fatigue)
                }.padding(.top, 8)
                Chart {
                    ForEach(recent) { state in
                        LineMark(x: .value(L("Day"), state.date, unit: .day), y: .value(L("Fitness"), state.fitness), series: .value("S", L("Fitness")))
                            .foregroundStyle(Tone.moss).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round)).interpolationMethod(.monotone)
                        LineMark(x: .value(L("Day"), state.date, unit: .day), y: .value(L("Fatigue"), state.fatigue), series: .value("S", L("Fatigue")))
                            .foregroundStyle(Tone.ink3).lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3])).interpolationMethod(.monotone)
                    }
                }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(Tone.hairline); AxisValueLabel().font(.caption2).foregroundStyle(Tone.ink3) } }
                .chartXAxis { AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption2).foregroundStyle(Tone.ink3) } }
                .frame(height: 170).padding(.top, 14)
                HStack(spacing: 14) { legend(Tone.moss, L("Fitness · 42-day")); legend(Tone.ink3, L("Fatigue · 7-day")) }.padding(.top, 10)
                Text(L("Positive form means recent load is below what you’re adapted to; negative form follows a hard block.")).font(.footnote).foregroundStyle(Tone.ink2).padding(.top, 10)
            } else {
                Text(L("Rate how hard each session felt (0–10). Load = effort × minutes feeds a fitness–fatigue model.")).font(.subheadline).foregroundStyle(Tone.ink2).padding(.top, 8)
            }
        }
        WorkloadCard()
        WeeklyLoadCard()
        CardioCard()
        Card(padding: 6) {
            NavigationLink { SessionsList() } label: {
                HStack {
                    Label(L("Sessions"), systemImage: "list.bullet").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(library.data.workouts.count)").foregroundStyle(Tone.ink3)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Tone.ink3)
                }.padding(12).foregroundStyle(Tone.ink)
            }.buttonStyle(PressStyle())
        }
    }
    private func stat(_ label: String, _ value: Double, signed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(signed ? Format.signed(value) : value.formatted(.number.precision(.fractionLength(0)))).font(.figure(34)).monospacedDigit()
            Text(L(label)).font(.caption).foregroundStyle(Tone.ink2)
        }
    }
    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) { Capsule().fill(color).frame(width: 12, height: 4); Text(L(text)).font(.caption2).foregroundStyle(Tone.ink2) }
    }
}

private struct WeeklyLoadCard: View {
    @EnvironmentObject private var library: AppStore
    private struct Week: Identifiable { let start: Date; let load: Double; var id: Date { start } }
    var body: some View {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        let weeks = (0..<8).reversed().map { offset -> Week in
            let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek)!
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            return Week(start: start, load: library.data.workouts.filter { $0.date >= start && $0.date < end }.compactMap(\.load).reduce(0, +))
        }
        if weeks.contains(where: { $0.load > 0 }) {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(L("Weekly load"))
                    Spacer()
                    Text(L("%@ this week", String(describing: Int(weeks.last!.load)))).font(.caption).foregroundStyle(Tone.ink2)
                }
                Chart(weeks) { week in
                    BarMark(x: .value(L("Week"), week.start, unit: .weekOfYear), y: .value(L("Load"), week.load), width: .ratio(0.55))
                        .foregroundStyle(week.start == thisWeek ? Tone.moss : Tone.moss.opacity(0.35)).clipShape(Capsule())
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption2).foregroundStyle(Tone.ink3) } }
                .frame(height: 110).padding(.top, 12)
            }
        }
    }
}

/// Acute:chronic workload ratio and weekly ramp.
private struct WorkloadCard: View {
    @EnvironmentObject private var library: AppStore
    var body: some View {
        let ratio = FitnessMath.workloadRatio(library.data.workouts)
        if let value = ratio.ratio {
            let balanced = value >= 0.8 && value <= 1.3
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(L("Workload ratio"))
                    Spacer()
                    Text(L(ratio.zone)).font(.caption.weight(.semibold)).padding(.horizontal, 8).frame(height: 24)
                        .foregroundStyle(balanced ? Tone.moss : Tone.signal)
                        .background((balanced ? Tone.mossSoft : Tone.signal.opacity(0.12)), in: Capsule())
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L(value.formatted(.number.precision(.fractionLength(2))))).font(.figure(44)).monospacedDigit()
                    Text(L("acute ÷ chronic")).font(.subheadline).foregroundStyle(Tone.ink2)
                    Spacer()
                    if let ramp = FitnessMath.weeklyRamp(library.data.workouts) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Format.signed(ramp) + "%").font(.figure(20)).monospacedDigit().foregroundStyle(abs(ramp) > 50 ? Tone.signal : Tone.ink)
                            Text(L("week ramp")).font(.caption2).foregroundStyle(Tone.ink3)
                        }
                    }
                }.padding(.top, 4)
                RangeBar(low: 0.8, high: 1.3, value: value, outside: !balanced).padding(.top, 10)
                Text(L("7-day load against your 28-day average (Williams et al., 2017). The 0.8–1.3 band is the common “sweet spot”; the ratio is debated, so treat it as context.")).font(.caption).foregroundStyle(Tone.ink3).padding(.top, 10)
            }
        }
    }
}

/// Heart-rate-ratio fitness estimate and training zones from age and resting HR.
struct CardioCard: View {
    @EnvironmentObject private var library: AppStore
    var body: some View {
        let resting = FitnessMath.trend(library.points(.restingPulse)).recent ?? library.points(.restingPulse).last?.value
        let maximum = library.data.profile.maximumHeartRate.map(Double.init) ?? library.data.profile.age.map(FitnessMath.maximumHeartRate)
        Card {
            Eyebrow(L("Cardio fitness"))
            if let resting, let maximum, let vo2 = FitnessMath.cardioFitness(maximum: maximum, resting: resting) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("≈ \(Int(vo2.rounded()))").font(.figure(40)).monospacedDigit()
                    Text(L("ml/kg/min VO₂max")).font(.subheadline).foregroundStyle(Tone.ink2)
                    Spacer()
                    if let age = library.data.profile.age, let category = FitnessMath.cardioCategory(vo2: vo2, age: age, sex: library.data.profile.sex) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(L(category.label)).font(.subheadline.weight(.semibold)).foregroundStyle(Tone.moss)
                            Text(L("~%@th pct", String(describing: category.percentile))).font(.caption2).foregroundStyle(Tone.ink3)
                        }
                    }
                }.padding(.top, 6)
                Text(L(library.data.profile.sex == .unspecified ? L("Estimated from max %@ and resting %@ bpm. Add your sex in Profile for an age-matched percentile.", String(describing: Int(maximum)), String(describing: Int(resting.rounded()))) : L("Estimated from max %@ and resting %@ bpm, ranked against age and sex norms. Expect ±10–15%% error.", String(describing: Int(maximum)), String(describing: Int(resting.rounded()))))).font(.caption).foregroundStyle(Tone.ink3)
                let floors = FitnessMath.zoneFloors(maximum: maximum, resting: resting)
                VStack(spacing: 6) {
                    ForEach(Array(floors.enumerated()), id: \.offset) { index, floor in
                        let ceiling = index + 1 < floors.count ? floors[index + 1] : maximum
                        HStack {
                            Text(L("Zone %@", String(describing: index + 1))).font(.footnote.weight(.medium))
                            Capsule().fill(Tone.moss.opacity(0.25 + Double(index) * 0.18)).frame(height: 6)
                            Text("\(Int(floor))–\(Int(ceiling))").font(.footnote).monospacedDigit().foregroundStyle(Tone.ink2).frame(width: 70, alignment: .trailing)
                        }
                    }
                }.padding(.top, 14)
            } else {
                Text(L(library.data.profile.age == nil ? L("Add your age in Band → Profile and import resting heart rate to estimate VO₂max and zones.") : L("Import resting heart rate from Apple Health to estimate VO₂max and zones.")))
                    .font(.subheadline).foregroundStyle(Tone.ink2).padding(.top, 8)
            }
        }
    }
}

struct SessionsList: View {
    @EnvironmentObject private var library: AppStore
    @State private var editing: WorkoutEntry?
    var body: some View {
        List {
            ForEach(library.data.workouts.sorted { $0.date > $1.date }) { workout in
                Button { editing = workout } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L(workout.activity)).font(.body.weight(.medium))
                            Text(L("%@ · %@ min · %@", String(describing: workout.date.formatted(date: .abbreviated, time: .shortened)), String(describing: Int(workout.minutes)), String(describing: workout.source))).font(.caption).foregroundStyle(Tone.ink2)
                        }
                        Spacer()
                        if let load = workout.load { Text("\(Int(load))").font(.figure(20)).monospacedDigit() }
                        else { Text(L("Rate")).font(.caption.weight(.semibold)).foregroundStyle(Tone.moss) }
                    }.foregroundStyle(Tone.ink)
                }
                .swipeActions { Button(L("Delete"), role: .destructive) { library.change { $0.workouts.removeAll { $0.id == workout.id } } } }
            }
            .listRowBackground(Tone.surface)
        }
        .overlay { if library.data.workouts.isEmpty { ContentUnavailableView(L("No sessions"), systemImage: "figure.run", description: Text(L("Start or log a session from Today."))) } }
        .navigationTitle(L("Sessions"))
        .sheet(item: $editing) { LogWorkoutSheet(existing: $0) }
    }
}
