import SwiftUI

let activities = ["Run", "Walk", "Ride", "Strength", "Intervals", "Swim", "Yoga", "Other"]

/// A live session: timer that survives relaunch, optional live heart rate with
/// time in zones, then a whole-session effort rating.
struct SessionScreen: View {
    @EnvironmentObject private var library: AppStore
    @EnvironmentObject private var live: LiveHeartRate
    @Environment(\.dismiss) private var dismiss
    @State private var zoneSeconds = [Double](repeating: 0, count: 5)
    @State private var pulseSum = 0.0
    @State private var pulseCount = 0
    @State private var lastSample: Date?
    @State private var finishing: WorkoutEntry?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let session = library.data.session { running(session) } else { start }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .sheet(item: $finishing) { entry in
                LogWorkoutSheet(existing: entry, isNew: true) { saved in
                    if saved { library.change { $0.session = nil }; live.stop(); dismiss() }
                }
            }
            .onChange(of: live.updatedAt) { _, _ in accumulate() }
        }
    }

    private var start: some View {
        VStack(spacing: 22) {
            Spacer()
            PebbleMark(size: 96, cutout: Tone.canvas)
            Text(L("What are you doing?")).font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                ForEach(activities, id: \.self) { activity in
                    Button { begin(activity) } label: {
                        Text(L(activity)).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 48)
                            .background(Tone.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(Tone.ink)
                    }.buttonStyle(PressStyle())
                }
            }
            .padding(.horizontal, 20)
            Spacer(); Spacer()
        }
    }

    private func running(_ session: WorkoutSession) -> some View {
        let floors = zoneFloors
        return VStack(spacing: 0) {
            Eyebrow(L(session.activity ?? L("Session"))).padding(.top, 24)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Duration.seconds(session.elapsed(at: context.date)).formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.figure(84, .medium)).monospacedDigit().foregroundStyle(session.paused ? Tone.ink3 : Tone.ink)
            }
            .padding(.top, 6)
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "heart.fill").foregroundStyle(Tone.heart)
                    Text(live.bpm.map(String.init) ?? "—").font(.figure(44)).monospacedDigit()
                    Text(L("bpm")).font(.footnote).foregroundStyle(Tone.ink2)
                    Spacer()
                    if let bpm = live.bpm, let floors, let zone = FitnessMath.zone(for: Double(bpm), floors: floors) {
                        Text(L("Zone %@", String(describing: zone + 1))).font(.subheadline.weight(.semibold)).foregroundStyle(Tone.moss)
                    }
                }
                switch live.state {
                case .off:
                    Button(L("Show live heart rate")) { live.start() }.font(.subheadline.weight(.semibold)).padding(.top, 8)
                    Text(L("Turn on Share heart rate for your Air in Google Health first.")).font(.caption).foregroundStyle(Tone.ink3).padding(.top, 2)
                case .searching: Text(L("Looking for your band…")).font(.caption).foregroundStyle(Tone.ink2).padding(.top, 8)
                case .streaming:
                    ZoneBars(seconds: zoneSeconds).padding(.top, 12)
                    if let rmssd = FitnessMath.rmssd(Array(live.rr.suffix(120))) {
                        Text(L("RMSSD %@ ms · last %@ beats", String(describing: Int(rmssd)), String(describing: min(live.rr.count, 120)))).font(.caption).foregroundStyle(Tone.ink3).padding(.top, 8)
                    }
                case .unavailable(let reason):
                    Text(L(reason)).font(.caption).foregroundStyle(Tone.signal).padding(.top, 8)
                    Button(L("Try again")) { live.start() }.font(.subheadline.weight(.semibold)).padding(.top, 4)
                }
            }
            .padding(.horizontal, 16).padding(.top, 24)
            Spacer()
            HStack(spacing: 12) {
                PillButton(title: session.paused ? L("Resume") : L("Pause"), symbol: session.paused ? "play.fill" : "pause.fill") {
                    library.change { data in
                        if data.session?.paused == true { data.session?.resume(at: Date()) } else { data.session?.pause(at: Date()) }
                    }
                }
                PillButton(title: L("Finish"), symbol: "checkmark", prominent: true) { finish(session) }
            }
            .padding(.bottom, 28)
            Button(L("Discard session"), role: .destructive) { library.change { $0.session = nil }; live.stop(); dismiss() }
                .font(.footnote).padding(.bottom, 12)
        }
    }

    private var zoneFloors: [Double]? {
        let profile = library.data.profile
        guard let maximum = profile.maximumHeartRate.map(Double.init) ?? profile.age.map(FitnessMath.maximumHeartRate),
              let resting = FitnessMath.trend(library.points(.restingPulse)).recent ?? library.points(.restingPulse).last?.value else { return nil }
        return FitnessMath.zoneFloors(maximum: maximum, resting: resting)
    }

    private func begin(_ activity: String) {
        library.change { $0.session = WorkoutSession(now: Date(), activity: activity) }
        zoneSeconds = Array(repeating: 0, count: 5); pulseSum = 0; pulseCount = 0; lastSample = nil
    }

    private func accumulate() {
        guard let bpm = live.bpm, let at = live.updatedAt, library.data.session?.paused == false else { lastSample = live.updatedAt; return }
        pulseSum += Double(bpm); pulseCount += 1
        if let lastSample, let floors = zoneFloors, let zone = FitnessMath.zone(for: Double(bpm), floors: floors) {
            zoneSeconds[zone] += min(5, at.timeIntervalSince(lastSample))
        }
        lastSample = at
    }

    private func finish(_ session: WorkoutSession) {
        let minutes = max(1, session.elapsed(at: Date()) / 60)
        finishing = WorkoutEntry(id: UUID(), date: session.startedAt, activity: session.activity ?? "Workout", minutes: minutes.rounded(), effort: nil, note: "", source: "Manual",
                                 averageHeartRate: pulseCount > 0 ? Int(pulseSum / Double(pulseCount)) : nil,
                                 zoneMinutes: zoneSeconds.contains { $0 > 0 } ? zoneSeconds.map { $0 / 60 } : nil)
    }
}

private struct ZoneBars: View {
    let seconds: [Double]
    var body: some View {
        let total = max(seconds.reduce(0, +), 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Tone.moss.opacity(0.3 + Double(index) * 0.17))
                        .frame(height: max(4, 44 * seconds[index] / total))
                    Text("\(Int(seconds[index] / 60))′").font(.caption2).monospacedDigit().foregroundStyle(Tone.ink2)
                }.frame(maxWidth: .infinity)
            }
        }
        .frame(height: 62)
        .accessibilityLabel(L("Time in heart rate zones"))
    }
}

/// Logs or edits a session with a whole-session effort rating (CR-10 scale).
struct LogWorkoutSheet: View {
    @EnvironmentObject private var library: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var entry: WorkoutEntry
    @State private var rated: Bool
    private let isNew: Bool
    private let onClose: ((Bool) -> Void)?
    init(existing: WorkoutEntry? = nil, isNew: Bool = false, onClose: ((Bool) -> Void)? = nil) {
        let base = existing ?? WorkoutEntry(id: UUID(), date: Date(), activity: "Run", minutes: 30, effort: nil, note: "", source: "Manual")
        _entry = State(initialValue: base); _rated = State(initialValue: base.effort != nil)
        self.isNew = isNew || existing == nil; self.onClose = onClose
    }
    private static let labels = [0: L("Rest"), 1: L("Very easy"), 2: L("Easy"), 3: L("Moderate"), 4: L("Somewhat hard"), 5: L("Hard"), 6: L("Hard"), 7: L("Very hard"), 8: L("Very hard"), 9: L("Very hard"), 10: L("Maximal")]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 6) {
                        Text(rated ? "\(entry.effort ?? 0)" : "–").font(.figure(64)).monospacedDigit()
                            .contentTransition(.numericText(value: Double(entry.effort ?? 0)))
                        Text(L(rated ? Self.labels[entry.effort ?? 0] ?? "" : L("How hard was the whole session?"))).font(.subheadline).foregroundStyle(Tone.ink2)
                        Slider(value: Binding(get: { Double(entry.effort ?? 5) }, set: { entry.effort = Int($0.rounded()); rated = true }), in: 0...10, step: 1)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .animation(.snappy, value: entry.effort)
                } footer: { Text(L("Rate the session as a whole, ideally around 30 minutes after. Load = effort × minutes (Foster et al., 2001).")) }
                Section {
                    Picker(L("Activity"), selection: $entry.activity) { ForEach(Array(Set(activities + [entry.activity])).sorted(), id: \.self) { Text(L($0)).tag($0) } }
                    DatePicker(L("Started"), selection: $entry.date)
                    Stepper(L("%@ min", String(describing: Int(entry.minutes))), value: $entry.minutes, in: 1...600, step: 5)
                    if let pulse = entry.averageHeartRate { LabeledContent(L("Average heart rate"), value: L("%@ bpm", String(describing: pulse))) }
                    if let zones = entry.zoneMinutes { LabeledContent(L("Zone load (Edwards)"), value: "\(Int(FitnessMath.edwardsLoad(zones)))") }
                    TextField(L("Note"), text: $entry.note, axis: .vertical)
                }
            }
            .navigationTitle(L(isNew ? L("Log session") : entry.activity)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { onClose?(false); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        if !rated { entry.effort = nil }
                        let saved = entry.valid && library.change { data in
                            data.workouts.removeAll { $0.id == entry.id }; data.workouts.append(entry)
                        }
                        onClose?(saved); dismiss()
                    }.fontWeight(.semibold)
                }
            }
        }
    }
}
