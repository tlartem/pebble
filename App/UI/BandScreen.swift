import SwiftUI
import UniformTypeIdentifiers

struct BandScreen: View {
    @EnvironmentObject private var band: BandConnection
    @EnvironmentObject private var library: AppStore
    @EnvironmentObject private var health: HealthImport
    @EnvironmentObject private var alerts: AlertCenter
    @EnvironmentObject private var keepAlive: KeepAlive

    var body: some View {
        NavigationStack {
            List {
                Section { DeviceHero() }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())

                Section {
                    if let haptic = band.haptic, let options = band.capabilities?.hapticIntensities, !library.preview {
                        Picker(L("Intensity"), selection: Binding(get: { haptic.intensity }, set: { band.setIntensity($0) })) {
                            ForEach(options.filter { (1...3).contains($0) }.sorted(), id: \.self) { Text(L(HapticSetting.name($0))).tag($0) }
                        }
                        .pickerStyle(.segmented).disabled(band.busy)
                    } else {
                        LabeledContent(L("Intensity"), value: library.preview ? L("High") : L("Sync to read"))
                    }
                    NavigationLink { PatternsView() } label: { Label(L("Patterns"), systemImage: "waveform") }
                } header: { Text(L("Vibration")) } footer: {
                    Text(L("The Air has no app-settable haptic patterns, so Pebble buzzes by briefly switching intensity and restoring it. Patterns differ by buzz count and spacing."))
                }

                Section {
                    ForEach(AlertEvent.allCases) { event in
                        NavigationLink { AlertEditor(event: event) } label: { AlertRow(event: event) }
                    }
                } header: { Text(L("Alerts")) } footer: {
                    if let message = alerts.lastMessage { Text(L("Last: %@", String(describing: message))) }
                }

                Section {
                    Toggle(isOn: Binding(get: { library.data.alerts.keepAlive }, set: setKeepAlive)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Keep Pebble running"))
                            Text(L("Calls and step alerts while locked")).font(.caption).foregroundStyle(Tone.ink2)
                        }
                    }
                    .disabled(library.preview)
                    if let next = alerts.nextCheck {
                        LabeledContent(L("Next step check"), value: next.formatted(date: .omitted, time: .shortened))
                    }
                } header: { Text(L("Background")) } footer: {
                    Text(L(library.data.alerts.keepAlive
                         ? L("Pebble stays active with a silent audio session. It uses extra iPhone battery and never plays sound or pauses your music.")
                         : L("Calls buzz while Pebble is open. Step alerts run when iOS allows a background refresh, which can be irregular.")))
                }

                Section(L("Connections")) {
                    NavigationLink { HealthView() } label: {
                        LabeledContent { Text(L(library.data.healthReadAt.map { Format.relative($0) } ?? L("Off"))) } label: { Label(L("Apple Health"), systemImage: "heart.text.square") }
                    }
                    NavigationLink { ShortcutsGuide() } label: { Label(L("Shortcuts & Siri"), systemImage: "square.2.layers.3d") }
                    NavigationLink { WebhookView() } label: {
                        LabeledContent { Text(L(library.data.alerts.webhookURL.isEmpty ? L("Off") : L("On"))) } label: { Label(L("Webhook"), systemImage: "point.3.connected.trianglepath.dotted") }
                    }
                    NavigationLink { ProfileView() } label: {
                        LabeledContent { Text(L(library.data.profile.age.map { L("%@ years", String(describing: $0)) } ?? L("Add age"))) } label: { Label(L("Profile"), systemImage: "person") }
                    }
                }

                Section {
                    LabeledContent(L("Status light"), value: L("Battery · firmware"))
                    LabeledContent(L("Double-tap"), value: L("Battery light · stop alarm"))
                    NavigationLink { EventsView() } label: { Text(L("Listen for band events")) }
                    NavigationLink { KeyView() } label: {
                        LabeledContent(L("Device key"), value: band.keysReady ? L("In Keychain") : L("Needed"))
                    }
                    ShareLink(L("Share connection report"), item: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("connection-report.json"))
                        .disabled(band.active || library.preview)
                } header: { Text(L("About the band")) } footer: {
                    Text(L("The light shows battery: white above 20%, red below. Its colour is set by the band’s firmware and can’t be changed by apps."))
                }

                Section {
                    NavigationLink { MethodsScreen() } label: { Text(L("Methods & sources")) }
                    Toggle(L("Example data"), isOn: Binding(get: { library.preview }, set: { on in library.setPreview(on); band.setPreview(on) }))
                        .disabled(band.active || health.busy)
                } footer: {
                    Text(L("Pebble %@ · No account, no analytics. Data stays on this iPhone.", String(describing: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")))
                }
            }
            .navigationTitle(L("Band"))
        }
    }

    private func setKeepAlive(_ on: Bool) {
        library.change { $0.alerts.keepAlive = on }
        on ? keepAlive.start() : keepAlive.stop()
        alerts.scheduleNextCheck()
    }
}

private struct DeviceHero: View {
    @EnvironmentObject private var band: BandConnection
    @EnvironmentObject private var library: AppStore
    @EnvironmentObject private var alerts: AlertCenter
    @State private var pattern = BuzzPattern.double
    var body: some View {
        VStack(spacing: 14) {
            PebbleMark(size: 112, cutout: Tone.canvas, glowing: band.active || alerts.delivering)
                .padding(.top, 6)
            VStack(spacing: 4) {
                Text("Fitbit Air").font(.title2.weight(.semibold))
                Text(L(subtitle)).font(.subheadline).foregroundStyle(Tone.ink2).multilineTextAlignment(.center)
                    .animation(.easeOut(duration: 0.2), value: subtitle)
            }
            HStack(spacing: 10) {
                PillButton(title: L("Sync"), symbol: "arrow.triangle.2.circlepath", busy: band.active && !alerts.delivering) { band.start() }
                    .disabled(!band.canStart)
                PillButton(title: L("Buzz"), symbol: "waveform", prominent: true, busy: alerts.delivering) {
                    Task { _ = await alerts.buzz(library.data.alerts.shortcutPattern) }
                }
                .disabled(!band.canStart || library.preview)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
    }
    private var subtitle: String {
        if library.preview { return L("Example data · nothing is sent to a band") }
        if band.active { return L(band.status) }
        if !band.keysReady { return L("Import your device key to connect") }
        var parts: [String] = []
        if let percent = band.deviceInfo?.batteryPercent { parts.append(L("%@%% battery", String(describing: percent))) }
        if band.lastSucceeded == false { parts.append(L(band.status)) }
        else if let read = band.lastRead { parts.append(L("synced ") + Format.relative(read)) }
        return parts.isEmpty ? L("Not synced yet") : parts.joined(separator: " · ").capitalizedFirst
    }
}

private extension String { var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() } }

private struct AlertRow: View {
    @EnvironmentObject private var library: AppStore
    let event: AlertEvent
    var body: some View {
        let rule = library.data.alerts.rule(event)
        HStack(spacing: 12) {
            Image(systemName: event.symbol).frame(width: 22).foregroundStyle(rule.enabled ? Tone.moss : Tone.ink3)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(event.title))
                Text(L(detail(rule))).font(.caption).foregroundStyle(Tone.ink2)
            }
            Spacer()
            if rule.enabled { PatternGlyph(pattern: rule.pattern, color: Tone.ink2) }
        }
    }
    private func detail(_ rule: AlertRule) -> String {
        guard rule.enabled else { return L("Off") }
        switch event {
        case .milestone: return L("Every %@ steps · %@", String(describing: library.data.alerts.milestoneStep.formatted()), String(describing: rule.pattern.title))
        case .goal: return L("%@ steps · %@", String(describing: library.data.goal.formatted()), String(describing: rule.pattern.title))
        case .move: return L("Under %@ steps in an hour · %@", String(describing: library.data.alerts.moveThreshold), String(describing: rule.pattern.title))
        case .shortcut: return L("Default %@", String(describing: rule.pattern.title))
        case .call: return rule.pattern.title
        }
    }
}

struct AlertEditor: View {
    @EnvironmentObject private var library: AppStore
    @EnvironmentObject private var alerts: AlertCenter
    @EnvironmentObject private var band: BandConnection
    let event: AlertEvent
    var body: some View {
        let settings = library.data.alerts
        let rule = settings.rule(event)
        Form {
            if event != .shortcut {
                Section {
                    Toggle(L("Buzz the band"), isOn: bind(\.enabled))
                } footer: { Text(L(explanation)) }
            }
            if rule.enabled {
                Section(L("Pattern")) {
                    ForEach(BuzzPattern.allCases) { pattern in
                        Button { update { $0.pattern = pattern } } label: {
                            HStack {
                                Text(L(pattern.title)).foregroundStyle(Tone.ink)
                                Spacer()
                                PatternGlyph(pattern: pattern, color: rule.pattern == pattern ? Tone.moss : Tone.ink3)
                                Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Tone.moss).opacity(rule.pattern == pattern ? 1 : 0)
                            }
                        }
                    }
                    Button { Task { _ = await alerts.buzz(rule.pattern) } } label: {
                        Label(alerts.delivering ? L("Buzzing…") : L("Try on band"), systemImage: "play.circle")
                    }.disabled(!band.canStart || alerts.delivering || library.preview)
                }
                switch event {
                case .goal:
                    Section(L("Goal")) {
                        Stepper(L("%@ steps", String(describing: library.data.goal.formatted())), value: Binding(get: { library.data.goal }, set: { v in library.change { $0.goal = v } }), in: 2000...40000, step: 500)
                    }
                case .milestone:
                    Section(L("Every")) {
                        Stepper(L("%@ steps", String(describing: settings.milestoneStep.formatted())), value: Binding(get: { settings.milestoneStep }, set: { v in library.change { $0.alerts.milestoneStep = v }; alerts.scheduleNextCheck() }), in: 500...10000, step: 500)
                    }
                case .move:
                    Section {
                        Stepper(L("Under %@ steps an hour", String(describing: settings.moveThreshold)), value: Binding(get: { settings.moveThreshold }, set: { v in library.change { $0.alerts.moveThreshold = v } }), in: 100...1000, step: 50)
                        Picker(L("From"), selection: Binding(get: { settings.activeStart }, set: { v in library.change { $0.alerts.activeStart = v } })) {
                            ForEach(5..<15, id: \.self) { Text(L(String(format: "%02d:00", $0))).tag($0) }
                        }
                        Picker(L("Until"), selection: Binding(get: { settings.activeEnd }, set: { v in library.change { $0.alerts.activeEnd = v } })) {
                            ForEach(15..<24, id: \.self) { Text(L(String(format: "%02d:00", $0))).tag($0) }
                        }
                    } header: { Text(L("Active hours")) }
                default: EmptyView()
                }
                if event != .call && event != .shortcut {
                    Section {
                        Toggle(L("iPhone notification"), isOn: Binding(get: { rule.notifyPhone }, set: { on in
                            update { $0.notifyPhone = on }; if on { alerts.requestNotificationPermission() }
                        }))
                        Toggle(L("Send to webhook"), isOn: bind(\.webhook)).disabled(settings.webhookURL.isEmpty)
                    } footer: { if settings.webhookURL.isEmpty { Text(L("Add a webhook URL in Band → Webhook to send events to your server.")) } }
                }
            }
            if event == .shortcut {
                Section { NavigationLink(L("Set up an automation")) { ShortcutsGuide() } }
            }
        }
        .navigationTitle(L(event.title)).navigationBarTitleDisplayMode(.inline)
    }
    private func update(_ body: @escaping (inout AlertRule) -> Void) {
        library.change { data in var rule = data.alerts.rule(event); body(&rule); data.alerts.set(event, rule) }
        alerts.scheduleNextCheck()
    }
    private func bind(_ path: WritableKeyPath<AlertRule, Bool>) -> Binding<Bool> {
        Binding(get: { library.data.alerts.rule(event)[keyPath: path] }, set: { value in update { $0[keyPath: path] = value } })
    }
    private var explanation: String {
        switch event {
        case .call: return L("Buzzes while an incoming call rings. Works with Pebble open, or locked when Keep Pebble running is on. Caller details are never read.")
        case .goal: return L("Once a day, when a band check finds you past your goal.")
        case .milestone: return L("Each time you pass another step multiple. Several crossed at once give one buzz.")
        case .move: return L("Breaking up long sitting with light walking improves blood sugar control (Dunstan et al., 2012).")
        case .shortcut: return ""
        }
    }
}

struct PatternsView: View {
    @EnvironmentObject private var alerts: AlertCenter
    @EnvironmentObject private var band: BandConnection
    @EnvironmentObject private var library: AppStore
    var body: some View {
        List {
            Section {
                ForEach(BuzzPattern.allCases) { pattern in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L(pattern.title))
                            Text(L(L("Buzz count: %@"), String(pattern.groups))).font(.caption).foregroundStyle(Tone.ink2)
                        }
                        Spacer()
                        PatternGlyph(pattern: pattern, color: Tone.ink2)
                        Button { Task { _ = await alerts.buzz(pattern) } } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless).padding(.leading, 12)
                            .disabled(!band.canStart || alerts.delivering || library.preview)
                            .accessibilityLabel(L("Try %@", String(describing: pattern.title)))
                    }
                }
            } footer: { Text(L("Each buzz is a brief intensity switch (~1 s over Bluetooth), so patterns differ by how many buzzes and the gaps between them, not fast rhythm. Vibration must not be set to Off.")) }
        }
        .navigationTitle(L("Patterns"))
    }
}

struct ShortcutsGuide: View {
    var body: some View {
        List {
            Section {
                step(1, L("Open Shortcuts → Automation → New Automation."))
                step(2, L("Choose Message or Email, then pick senders or words."))
                step(3, L("Select Run Immediately."))
                step(4, L("Add the Pebble action Buzz Band and choose a pattern."))
            } header: { Text(L("Forward messages to your band")) } footer: {
                Text(L("iOS doesn’t let apps read other apps’ notifications. Automations are Apple’s supported route, and run without opening Pebble."))
            }
            Section(L("Also available")) {
                Label(L("Get Steps — use in widgets, Siri or other automations"), systemImage: "figure.walk")
                Label(L("Get Band Battery"), systemImage: "battery.75percent")
                Label(L("“Hey Siri, Pebble buzz”"), systemImage: "mic")
            }
            Section { Link(L("Open Shortcuts"), destination: URL(string: "shortcuts://")!) }
        }
        .navigationTitle(L("Shortcuts & Siri"))
    }
    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.figure(20)).foregroundStyle(Tone.moss).frame(width: 18)
            Text(L(text))
        }
    }
}

struct WebhookView: View {
    @EnvironmentObject private var library: AppStore
    @State private var text = ""
    var body: some View {
        Form {
            Section {
                TextField("https://example.com/pebble", text: $text)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(save)
            } footer: {
                Text(L("Pebble POSTs JSON such as {\"event\":\"goal\",\"steps\":10240,\"time\":\"…\"} for alerts with Send to webhook on. Use it to trigger Home Assistant, n8n or your own server."))
            }
            Section { Button(L("Save"), action: save).disabled(!valid && !text.isEmpty) }
        }
        .navigationTitle(L("Webhook")).navigationBarTitleDisplayMode(.inline)
        .onAppear { text = library.data.alerts.webhookURL }
    }
    private var valid: Bool { URL(string: text).map { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil } ?? false }
    private func save() { if valid || text.isEmpty { library.change { $0.alerts.webhookURL = text.trimmingCharacters(in: .whitespaces) } } }
}

struct ProfileView: View {
    @EnvironmentObject private var library: AppStore
    var body: some View {
        Form {
            Section {
                Stepper(library.data.profile.age.map { L("Age %@", String(describing: $0)) } ?? L("Age not set"), value: Binding(get: { library.data.profile.age ?? 35 }, set: { v in library.change { $0.profile.age = v } }), in: 14...100)
                Picker(L("Sex"), selection: Binding(get: { library.data.profile.sex }, set: { v in library.change { $0.profile.sex = v } })) {
                    Text(L("Not set")).tag(Sex.unspecified); Text(L("Female")).tag(Sex.female); Text(L("Male")).tag(Sex.male)
                }
                Stepper(library.data.profile.maximumHeartRate.map { L("Max heart rate %@", String(describing: $0)) } ?? L("Max heart rate: estimated"), value: Binding(get: { library.data.profile.maximumHeartRate ?? Int(FitnessMath.maximumHeartRate(age: library.data.profile.age ?? 35)) }, set: { v in library.change { $0.profile.maximumHeartRate = v } }), in: 120...220)
                if library.data.profile.maximumHeartRate != nil { Button(L("Use estimate")) { library.change { $0.profile.maximumHeartRate = nil } } }
            } footer: { Text(L("Max heart rate is estimated as 208 − 0.7 × age (Tanaka et al., 2001) unless you set a measured value. Age and sex rank your VO₂max against population norms; sex is used only for that.")) }
        }
        .navigationTitle(L("Profile")).navigationBarTitleDisplayMode(.inline)
    }
}

struct HealthView: View {
    @EnvironmentObject private var library: AppStore
    @EnvironmentObject private var health: HealthImport
    var body: some View {
        Form {
            Section {
                Button(health.busy ? L("Importing…") : L("Import from Apple Health")) { health.refresh(into: library) }.disabled(health.busy || library.preview)
                if let message = health.message { Text(L(message)).font(.footnote).foregroundStyle(Tone.ink2) }
            } footer: { Text(L("Reads the last 90 days of steps, sleep, resting heart rate, HRV and workouts. Pebble never writes to Health, and keeps each source separate.")) }
            ForEach([MetricKind.steps, .sleepHours, .restingPulse, .hrvSDNN]) { kind in
                let options = library.sourceOptions(kind)
                if !options.isEmpty {
                    Section(kind.title) {
                        Picker(L("Source"), selection: Binding(get: { library.points(kind).first?.sourceID ?? "" }, set: { id in library.change { $0.sources[kind.rawValue] = id } })) {
                            ForEach(options, id: \.id) { Text(L($0.name)).tag($0.id) }
                        }
                    }
                }
            }
            Section {
                Button(L("Remove imported history"), role: .destructive) {
                    library.change { data in data.metrics.removeAll { $0.sourceID != "air" }; data.workouts.removeAll { $0.source != "Manual" }; data.healthReadAt = nil }
                }.disabled(library.preview)
            }
        }
        .navigationTitle(L("Apple Health")).navigationBarTitleDisplayMode(.inline)
    }
}

/// Read-only listening window used to discover band events such as taps.
struct EventsView: View {
    @EnvironmentObject private var band: BandConnection
    var body: some View {
        List {
            Section {
                Button(band.observingEvents ? L("Listening…") : L("Listen for 2 minutes")) { band.observeEvents() }
                    .disabled(!band.canStart)
                if band.observingEvents { SyncLine() }
            } footer: { Text(L("While listening, firmly double-tap the band a few times or take it off and on. Pebble records event names the band sends. Nothing is changed on the band.")) }
            if !band.observedEvents.isEmpty {
                Section(L("Received")) {
                    ForEach(band.observedEvents) { event in
                        LabeledContent(event.name, value: event.date.formatted(date: .omitted, time: .standard)).monospaced()
                    }
                }
            }
        }
        .navigationTitle(L("Band events")).navigationBarTitleDisplayMode(.inline)
    }
}

struct KeyView: View {
    @EnvironmentObject private var band: BandConnection
    @EnvironmentObject private var library: AppStore
    @State private var importing = false
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                LabeledContent(L("Status"), value: band.keysReady ? L("Stored on this iPhone") : L("Not imported"))
                Button(L("Import key file")) { importing = true }.disabled(library.preview || band.active)
                PasteButton(payloadType: String.self) { values in
                    if let text = values.first { importKeys(Data(text.utf8)) }
                }
                .disabled(library.preview || band.active)
                if let message { Text(L(message)).font(.footnote).foregroundStyle(Tone.ink2) }
            } footer: { Text(L("Your Air’s two device keys secure the Bluetooth session. They live in this iPhone’s Keychain, never leave the device, and aren’t in any backup.")) }
        }
        .navigationTitle(L("Device key")).navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                importKeys(try Data(contentsOf: url))
            } catch { message = L("Couldn’t read the file. Try the Paste button.") }
        }
    }

    private func importKeys(_ data: Data) {
        do {
            guard data.count <= 16384 else { throw DeviceKeys.Failure.invalid }
            let keys = try JSONDecoder().decode(DeviceKeys.self, from: data); try keys.validate()
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("device-keys.json")
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            _ = try DeviceKeys.load(); band.refreshKeys()
            message = L("Keys stored. You can delete the file you imported.")
        } catch DeviceKeys.Failure.keychain {
            message = L("Couldn’t save keys in Keychain. Check the app’s signing profile.")
        } catch {
            message = L("That text or file doesn’t contain two valid Air device keys.")
        }
    }
}
