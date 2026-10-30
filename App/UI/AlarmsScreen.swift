import SwiftUI

struct AlarmsScreen: View {
    @EnvironmentObject private var band: BandConnection
    @State private var editing: BandAlarm?
    @State private var adding = false
    @State private var deleting: BandAlarm?

    var body: some View {
        NavigationStack {
            List {
                if let list = band.alarms {
                    Section {
                        ForEach(list.alarms) { alarm in
                            AlarmRow(alarm: alarm, busy: band.busy) { editing = alarm } toggle: { on in
                                band.save(alarm, hour: alarm.hour, minute: alarm.minute, enabled: on, smartWake: alarm.smartWake)
                            }
                            .swipeActions { Button(L("Delete"), role: .destructive) { deleting = alarm }.disabled(band.busy) }
                        }
                    } footer: {
                        Text(L("%@ of %@ · Firmly double-tap the band to stop a ringing alarm.", String(describing: list.alarms.count), String(describing: list.maximum)))
                            .font(.footnote).foregroundStyle(Tone.ink3).padding(.top, 6)
                    }
                    .listRowBackground(Tone.surface)
                } else {
                    ContentUnavailableView {
                        Label(L("No alarms yet"), systemImage: "alarm")
                    } description: {
                        Text(L(band.keysReady ? L("Pull down to read the alarms saved on your band.") : L("Connect your band in the Band tab.")))
                    }
                    .listRowBackground(Color.clear)
                }
                if band.active || band.lastSucceeded == false {
                    Section { SyncLine() }.listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L("Alarms"))
            .refreshable { if band.canStart { _ = await band.run { band.start() } } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Add alarm"), systemImage: "plus") { adding = true }
                        .disabled(band.busy || band.alarms == nil || (band.alarms?.alarms.count ?? 0) >= (band.alarms?.maximum ?? 0))
                }
            }
            .sheet(isPresented: $adding) { AlarmEditor(alarm: nil) }
            .sheet(item: $editing) { AlarmEditor(alarm: $0) }
            .confirmationDialog(L("Delete this alarm from your band?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button(L("Delete alarm"), role: .destructive) { if let deleting { band.delete(deleting) }; deleting = nil }
            }
        }
    }
}

private struct AlarmRow: View {
    let alarm: BandAlarm
    let busy: Bool
    let open: () -> Void
    let toggle: (Bool) -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(alarm.time)).font(.figure(52, .light)).monospacedDigit()
                        .foregroundStyle(alarm.enabled ? Tone.ink : Tone.ink3)
                    Text(L(alarm.schedule + (alarm.smartWake ? L(" · Smart wake") : "")))
                        .font(.subheadline).foregroundStyle(Tone.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle()).disabled(busy)
            Toggle(L("Enabled"), isOn: Binding(get: { alarm.enabled }, set: toggle)).labelsHidden().disabled(busy)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alarm.time), \(alarm.schedule), \(alarm.enabled ? L("on") : L("off"))")
    }
}

struct SyncLine: View {
    @EnvironmentObject private var band: BandConnection
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if band.active { ProgressView().controlSize(.small) }
            else { Image(systemName: "exclamationmark.circle").foregroundStyle(Tone.signal) }
            VStack(alignment: .leading, spacing: 2) {
                Text(L(band.status)).font(.subheadline.weight(.medium))
                Text(L(band.detail)).font(.caption).foregroundStyle(Tone.ink2)
            }
        }
        .animation(.easeOut(duration: 0.2), value: band.status)
    }
}

struct AlarmEditor: View {
    @EnvironmentObject private var band: BandConnection
    @Environment(\.dismiss) private var dismiss
    let alarm: BandAlarm?
    @State private var time: Date
    @State private var enabled: Bool
    @State private var smartWake: Bool
    @State private var days: UInt8
    @State private var confirmDelete = false
    init(alarm: BandAlarm?) {
        self.alarm = alarm
        _time = State(initialValue: Calendar.current.date(from: DateComponents(hour: alarm?.hour ?? 7, minute: alarm?.minute ?? 0)) ?? Date())
        _enabled = State(initialValue: alarm?.enabled ?? true)
        _smartWake = State(initialValue: alarm?.smartWake ?? false)
        _days = State(initialValue: alarm?.recurring == true ? alarm!.days : 0)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(L("Time"), selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                }
                Section {
                    DayPicker(days: $days)
                } header: { Text(L("Repeat")) } footer: { Text(L(summary)) }
                Section {
                    Toggle(L("Alarm on"), isOn: $enabled)
                    if band.alarms?.smartWakeSupported == true {
                        Toggle(isOn: $smartWake) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Smart wake"))
                                Text(L("May vibrate up to 30 min early, during lighter sleep.")).font(.caption).foregroundStyle(Tone.ink2)
                            }
                        }
                    }
                } footer: {
                    if alarm == nil && !enabled { Text(L("Air turns new alarms on. Pebble switches it off right after and checks the result.")) }
                }
                if alarm != nil {
                    Section { Button(L("Delete alarm"), role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(L(alarm == nil ? L("New alarm") : L("Edit alarm"))).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Save"), action: save).fontWeight(.semibold).disabled(band.busy) }
            }
            .confirmationDialog(L("Delete this alarm from your band?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L("Delete alarm"), role: .destructive) { if let alarm { band.delete(alarm) }; dismiss() }
            }
        }
    }
    private var summary: String {
        switch days {
        case 0: return L("Rings once.")
        case 127: return L("Every day.")
        case 31: return L("Weekdays.")
        case 96: return L("Weekends.")
        default: return L("%@ days a week.", String(describing: days.nonzeroBitCount))
        }
    }
    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hour = parts.hour ?? 7, minute = parts.minute ?? 0
        if let alarm { band.save(alarm, hour: hour, minute: minute, enabled: enabled, smartWake: smartWake, days: days) }
        else { band.create(AlarmDraft(hour: hour, minute: minute, enabled: enabled, smartWake: smartWake, days: days)) }
        dismiss()
    }
}

/// Seven round day toggles, Monday first (bit 0) to match the band.
struct DayPicker: View {
    @Binding var days: UInt8
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                let on = days & UInt8(1 << index) != 0
                Button { days ^= UInt8(1 << index) } label: {
                    Text(Calendar.current.veryShortStandaloneWeekdaySymbols[(index + 1) % 7]).font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(on ? Tone.onMoss : Tone.ink)
                        .background(on ? Tone.moss : Tone.sunken, in: Circle())
                }
                .buttonStyle(PressStyle())
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Calendar.current.weekdaySymbols[(index + 1) % 7]).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: days)
    }
}
