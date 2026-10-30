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
                        Picker("Intensity", selection: Binding(get: { haptic.intensity }, set: { band.setIntensity($0) })) {
                            ForEach(options.filter { (1...3).contains($0) }.sorted(), id: \.self) { Text(HapticSetting.name($0)).tag($0) }
                        }
                        .pickerStyle(.segmented).disabled(band.busy)
                    } else {
                        LabeledContent("Intensity", value: library.preview ? "High" : "Sync to read")
                    }
                    NavigationLink { PatternsView() } label: { Label("Patterns", systemImage: "waveform") }
                } header: { Text("Vibration") } footer: {
                    Text("The Air has no app-settable haptic patterns, so Pebble buzzes by briefly switching intensity and restoring it. Patterns differ by buzz count and spacing.")
                }

                Section {
                    ForEach(AlertEvent.allCases) { event in
                        NavigationLink { AlertEditor(event: event) } label: { AlertRow(event: event) }
                    }
                } header: { Text("Alerts") } footer: {
                    if let message = alerts.lastMessage { Text("Last: \(message)") }
                }

                Section {
                    Toggle(isOn: Binding(get: { library.data.alerts.keepAlive }, set: setKeepAlive)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep Pebble running")
                            Text("Calls and step alerts while locked").font(.caption).foregroundStyle(Tone.ink2)
                        }
                    }
                    .disabled(library.preview)
                    if let next = alerts.nextCheck {
                        LabeledContent("Next step check", value: next.formatted(date: .omitted, time: .shortened))
                    }
                } header: { Text("Background") } footer: {
                    Text(library.data.alerts.keepAlive
                         ? "Pebble stays active with a silent audio session. It uses extra iPhone battery and never plays sound or pauses your music."
                         : "Calls buzz while Pebble is open. Step alerts run when iOS allows a background refresh, which can be irregular.")
                }

                Section("Connections") {
                    NavigationLink { HealthView() } label: {
                        LabeledContent { Text(library.data.healthReadAt.map { Format.relative($0) } ?? "Off") } label: { Label("Apple Health", systemImage: "heart.text.square") }
                    }
                    NavigationLink { ShortcutsGuide() } label: { Label("Shortcuts & Siri", systemImage: "square.2.layers.3d") }
                    NavigationLink { WebhookView() } label: {
                        LabeledContent { Text(library.data.alerts.webhookURL.isEmpty ? "Off" : "On") } label: { Label("Webhook", systemImage: "point.3.connected.trianglepath.dotted") }
                    }
                    NavigationLink { ProfileView() } label: {
                        LabeledContent { Text(library.data.profile.age.map { "\($0) years" } ?? "Add age") } label: { Label("Profile", systemImage: "person") }
                    }
                }

                Section {
                    LabeledContent("Status light", value: "Battery · firmware")
                    LabeledContent("Double-tap", value: "Battery light · stop alarm")
                    NavigationLink { EventsView() } label: { Text("Listen for band events") }
                    NavigationLink { KeyView() } label: {
                        LabeledContent("Device key", value: band.keysReady ? "In Keychain" : "Needed")
                    }
                } header: { Text("About the band") } footer: {
                    Text("The light shows battery: white above 20%, red below. Its colour is set by the band’s firmware and can’t be changed by apps.")
                }

                Section {
                    NavigationLink { MethodsScreen() } label: { Text("Methods & sources") }
                    Toggle("Example data", isOn: Binding(get: { library.preview }, set: { on in library.setPreview(on); band.setPreview(on) }))
                        .disabled(band.active || health.busy)
                } footer: {
                    Text("Pebble \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · No account, no analytics. Data stays on this iPhone.")
                }
            }
            .surfaceRows()
            .navigationTitle("Band")
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
                Text(subtitle).font(.subheadline).foregroundStyle(Tone.ink2).multilineTextAlignment(.center)
                    .animation(.easeOut(duration: 0.2), value: subtitle)
            }
            HStack(spacing: 10) {
                PillButton(title: "Sync", symbol: "arrow.triangle.2.circlepath", busy: band.active && !alerts.delivering) { band.start() }
                    .disabled(!band.canStart)
                PillButton(title: "Buzz", symbol: "waveform", prominent: true, busy: alerts.delivering) {
                    Task { _ = await alerts.buzz(library.data.alerts.shortcutPattern) }
                }
                .disabled(!band.canStart || library.preview)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
    }
    private var subtitle: String {
        if library.preview { return "Example data · nothing is sent to a band" }
        if band.active { return band.status }
        if !band.keysReady { return "Import your device key to connect" }
        var parts: [String] = []
        if let percent = band.deviceInfo?.batteryPercent { parts.append("\(percent)% battery") }
        if band.lastSucceeded == false { parts.append(band.status) }
        else if let read = band.lastRead { parts.append("synced " + Format.relative(read)) }
        return parts.isEmpty ? "Not synced yet" : parts.joined(separator: " · ").capitalizedFirst
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
                Text(event.title)
                Text(detail(rule)).font(.caption).foregroundStyle(Tone.ink2)
            }
            Spacer()
            if rule.enabled { PatternGlyph(pattern: rule.pattern, color: Tone.ink2) }
        }
    }
    private func detail(_ rule: AlertRule) -> String {
        guard rule.enabled else { return "Off" }
        switch event {
        case .milestone: return "Every \(library.data.alerts.milestoneStep.formatted()) steps · \(rule.pattern.title)"
        case .goal: return "\(library.data.goal.formatted()) steps · \(rule.pattern.title)"
        case .move: return "Under \(library.data.alerts.moveThreshold) steps in an hour · \(rule.pattern.title)"
        case .shortcut: return "Default \(rule.pattern.title)"
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
                    Toggle("Buzz the band", isOn: bind(\.enabled))
                } footer: { Text(explanation) }
            }
            if rule.enabled {
                Section("Pattern") {
                    ForEach(BuzzPattern.allCases) { pattern in
                        Button { update { $0.pattern = pattern } } label: {
                            HStack {
                                Text(pattern.title).foregroundStyle(Tone.ink)
                                Spacer()
                                PatternGlyph(pattern: pattern, color: rule.pattern == pattern ? Tone.moss : Tone.ink3)
                                Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Tone.moss).opacity(rule.pattern == pattern ? 1 : 0)
                            }
                        }
                    }
                    Button { Task { _ = await alerts.buzz(rule.pattern) } } label: {
                        Label(alerts.delivering ? "Buzzing…" : "Try on band", systemImage: "play.circle")
                    }.disabled(!band.canStart || alerts.delivering || library.preview)
                }
                switch event {
                case .goal:
                    Section("Goal") {
                        Stepper("\(library.data.goal.formatted()) steps", value: Binding(get: { library.data.goal }, set: { v in library.change { $0.goal = v } }), in: 2000...40000, step: 500)
                    }
                case .milestone:
                    Section("Every") {
                        Stepper("\(settings.milestoneStep.formatted()) steps", value: Binding(get: { settings.milestoneStep }, set: { v in library.change { $0.alerts.milestoneStep = v }; alerts.scheduleNextCheck() }), in: 500...10000, step: 500)
                    }
                case .move:
                    Section {
                        Stepper("Under \(settings.moveThreshold) steps an hour", value: Binding(get: { settings.moveThreshold }, set: { v in library.change { $0.alerts.moveThreshold = v } }), in: 100...1000, step: 50)
                        Picker("From", selection: Binding(get: { settings.activeStart }, set: { v in library.change { $0.alerts.activeStart = v } })) {
                            ForEach(5..<15, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                        Picker("Until", selection: Binding(get: { settings.activeEnd }, set: { v in library.change { $0.alerts.activeEnd = v } })) {
                            ForEach(15..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                    } header: { Text("Active hours") }
                default: EmptyView()
                }
                if event != .call && event != .shortcut {
                    Section {
                        Toggle("iPhone notification", isOn: Binding(get: { rule.notifyPhone }, set: { on in
                            update { $0.notifyPhone = on }; if on { alerts.requestNotificationPermission() }
                        }))
                        Toggle("Send to webhook", isOn: bind(\.webhook)).disabled(settings.webhookURL.isEmpty)
                    } footer: { if settings.webhookURL.isEmpty { Text("Add a webhook URL in Band → Webhook to send events to your server.") } }
                }
            }
            if event == .shortcut {
                Section { NavigationLink("Set up an automation") { ShortcutsGuide() } }
            }
        }
        .surfaceRows()
        .navigationTitle(event.title).navigationBarTitleDisplayMode(.inline)
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
        case .call: return "Buzzes while an incoming call rings. Works with Pebble open, or locked when Keep Pebble running is on. Caller details are never read."
        case .goal: return "Once a day, when a band check finds you past your goal."
        case .milestone: return "Each time you pass another step multiple. Several crossed at once give one buzz."
        case .move: return "Breaking up long sitting with light walking improves blood sugar control (Dunstan et al., 2012)."
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
                            Text(pattern.title)
                            Text("\(pattern.groups) buzz\(pattern.groups == 1 ? "" : "es")").font(.caption).foregroundStyle(Tone.ink2)
                        }
                        Spacer()
                        PatternGlyph(pattern: pattern, color: Tone.ink2)
                        Button { Task { _ = await alerts.buzz(pattern) } } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless).padding(.leading, 12)
                            .disabled(!band.canStart || alerts.delivering || library.preview)
                            .accessibilityLabel("Try \(pattern.title)")
                    }
                }
            } footer: { Text("Each buzz is a brief intensity switch (~1 s over Bluetooth), so patterns differ by how many buzzes and the gaps between them, not fast rhythm. Vibration must not be set to Off.") }
        }
        .surfaceRows()
        .navigationTitle("Patterns")
    }
}

struct ShortcutsGuide: View {
    var body: some View {
        List {
            Section {
                step(1, "Open Shortcuts → Automation → New Automation.")
                step(2, "Choose Message or Email, then pick senders or words.")
                step(3, "Select Run Immediately.")
                step(4, "Add the Pebble action Buzz Band and choose a pattern.")
            } header: { Text("Forward messages to your band") } footer: {
                Text("iOS doesn’t let apps read other apps’ notifications. Automations are Apple’s supported route, and run without opening Pebble.")
            }
            Section("Also available") {
                Label("Get Steps — use in widgets, Siri or other automations", systemImage: "figure.walk")
                Label("Get Band Battery", systemImage: "battery.75percent")
                Label("“Hey Siri, Pebble buzz”", systemImage: "mic")
            }
            Section { Link("Open Shortcuts", destination: URL(string: "shortcuts://")!) }
        }
        .surfaceRows()
        .navigationTitle("Shortcuts & Siri")
    }
    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.figure(20)).foregroundStyle(Tone.moss).frame(width: 18)
            Text(text)
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
                Text("Pebble POSTs JSON such as {\"event\":\"goal\",\"steps\":10240,\"time\":\"…\"} for alerts with Send to webhook on. Use it to trigger Home Assistant, n8n or your own server.")
            }
            Section { Button("Save", action: save).disabled(!valid && !text.isEmpty) }
        }
        .surfaceRows()
        .navigationTitle("Webhook").navigationBarTitleDisplayMode(.inline)
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
                Stepper(library.data.profile.age.map { "Age \($0)" } ?? "Age not set", value: Binding(get: { library.data.profile.age ?? 35 }, set: { v in library.change { $0.profile.age = v } }), in: 14...100)
                Picker("Sex", selection: Binding(get: { library.data.profile.sex }, set: { v in library.change { $0.profile.sex = v } })) {
                    Text("Not set").tag(Sex.unspecified); Text("Female").tag(Sex.female); Text("Male").tag(Sex.male)
                }
                Stepper(library.data.profile.maximumHeartRate.map { "Max heart rate \($0)" } ?? "Max heart rate: estimated", value: Binding(get: { library.data.profile.maximumHeartRate ?? Int(FitnessMath.maximumHeartRate(age: library.data.profile.age ?? 35)) }, set: { v in library.change { $0.profile.maximumHeartRate = v } }), in: 120...220)
                if library.data.profile.maximumHeartRate != nil { Button("Use estimate") { library.change { $0.profile.maximumHeartRate = nil } } }
            } footer: { Text("Max heart rate is estimated as 208 − 0.7 × age (Tanaka et al., 2001) unless you set a measured value. Age and sex rank your VO₂max against population norms; sex is used only for that.") }
        }
        .surfaceRows()
        .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
    }
}

struct HealthView: View {
    @EnvironmentObject private var library: AppStore
    @EnvironmentObject private var health: HealthImport
    var body: some View {
        Form {
            Section {
                Button(health.busy ? "Importing…" : "Import from Apple Health") { health.refresh(into: library) }.disabled(health.busy || library.preview)
                if let message = health.message { Text(message).font(.footnote).foregroundStyle(Tone.ink2) }
            } footer: { Text("Reads the last 90 days of steps, sleep, resting heart rate, HRV and workouts. Pebble never writes to Health, and keeps each source separate.") }
            ForEach([MetricKind.steps, .sleepHours, .restingPulse, .hrvSDNN]) { kind in
                let options = library.sourceOptions(kind)
                if !options.isEmpty {
                    Section(kind.title) {
                        Picker("Source", selection: Binding(get: { library.points(kind).first?.sourceID ?? "" }, set: { id in library.change { $0.sources[kind.rawValue] = id } })) {
                            ForEach(options, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    }
                }
            }
            Section {
                Button("Remove imported history", role: .destructive) {
                    library.change { data in data.metrics.removeAll { $0.sourceID != "air" }; data.workouts.removeAll { $0.source != "Manual" }; data.healthReadAt = nil }
                }.disabled(library.preview)
            }
        }
        .surfaceRows()
        .navigationTitle("Apple Health").navigationBarTitleDisplayMode(.inline)
    }
}

/// Read-only listening window used to discover band events such as taps.
struct EventsView: View {
    @EnvironmentObject private var band: BandConnection
    var body: some View {
        List {
            Section {
                Button(band.observingEvents ? "Listening…" : "Listen for 2 minutes") { band.observeEvents() }
                    .disabled(!band.canStart)
                if band.observingEvents { SyncLine() }
            } footer: { Text("While listening, firmly double-tap the band a few times or take it off and on. Pebble records event names the band sends. Nothing is changed on the band.") }
            if !band.observedEvents.isEmpty {
                Section("Received") {
                    ForEach(band.observedEvents) { event in
                        LabeledContent(event.name, value: event.date.formatted(date: .omitted, time: .standard)).monospaced()
                    }
                }
            }
        }
        .surfaceRows()
        .navigationTitle("Band events").navigationBarTitleDisplayMode(.inline)
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
                LabeledContent("Status", value: band.keysReady ? "Stored on this iPhone" : "Not imported")
                Button("Import key file") { importing = true }.disabled(library.preview || band.active)
                PasteButton(payloadType: String.self) { values in
                    if let text = values.first { importKeys(Data(text.utf8)) }
                }
                .disabled(library.preview || band.active)
                if let message { Text(message).font(.footnote).foregroundStyle(Tone.ink2) }
            } footer: { Text("Your Air’s two device keys secure the Bluetooth session. They live in this iPhone’s Keychain, never leave the device, and aren’t in any backup.") }
        }
        .surfaceRows()
        .navigationTitle("Device key").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                importKeys(try Data(contentsOf: url))
            } catch { message = "Couldn’t read the file. Try the Paste button." }
        }
    }

    private func importKeys(_ data: Data) {
        do {
            guard data.count <= 16384 else { throw DeviceKeys.Failure.invalid }
            let keys = try JSONDecoder().decode(DeviceKeys.self, from: data); try keys.validate()
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("device-keys.json")
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            _ = try DeviceKeys.load(); band.refreshKeys()
            message = "Keys stored. You can delete the file you imported."
        } catch DeviceKeys.Failure.keychain {
            message = "Couldn’t save keys in Keychain. Check the app’s signing profile."
        } catch {
            message = "That text or file doesn’t contain two valid Air device keys."
        }
    }
}
