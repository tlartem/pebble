import AppIntents

enum PatternOption: String, AppEnum {
    case single, double, triple, longGap, urgent
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Pattern"
    static var caseDisplayRepresentations: [PatternOption: DisplayRepresentation] = [
        .single: "Single", .double: "Double", .triple: "Triple", .longGap: "Long gap", .urgent: "Urgent",
    ]
    var pattern: BuzzPattern { BuzzPattern(rawValue: rawValue) ?? .double }
}

/// Use from a Shortcuts personal automation (for example "When I get a message
/// from…") to forward that event to the band. Runs without opening Pebble.
struct BuzzBandIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Band"
    static var description = IntentDescription("Vibrates your Fitbit Air with a pattern.")
    static var openAppWhenRun = false
    @Parameter(title: "Pattern", default: .double) var pattern: PatternOption
    static var parameterSummary: some ParameterSummary { Summary("Buzz band with \(\.$pattern)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await Services.shared.alerts.buzz(pattern.pattern)
        let dialog: IntentDialog = ok ? "Buzzed your band." : "Your band is busy or out of range."
        return .result(dialog: dialog)
    }
}

struct StepCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Steps"
    static var description = IntentDescription("Reads today’s step count from your Fitbit Air.")
    static var openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let band = Services.shared.band
        if await band.waitUntilIdle(seconds: 10) { _ = await band.run { band.readActivity() } }
        guard let reading = band.activity, Calendar.current.isDateInToday(reading.readAt), let steps = reading.steps else {
            return .result(value: 0, dialog: "Couldn’t read steps right now.")
        }
        return .result(value: steps, dialog: "\(steps.formatted()) steps today.")
    }
}

struct BatteryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Band Battery"
    static var description = IntentDescription("Reads your Fitbit Air’s battery level.")
    static var openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let band = Services.shared.band
        if await band.waitUntilIdle(seconds: 10) { _ = await band.run { band.start() } }
        guard let percent = band.deviceInfo?.batteryPercent else { return .result(value: -1, dialog: "Battery unavailable right now.") }
        return .result(value: percent, dialog: "Your band is at \(percent)%.")
    }
}

struct PebbleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BuzzBandIntent(), phrases: ["Buzz my band with \(.applicationName)", "\(.applicationName) buzz"],
                    shortTitle: "Buzz Band", systemImageName: "waveform")
        AppShortcut(intent: StepCountIntent(), phrases: ["How many steps in \(.applicationName)", "\(.applicationName) steps"],
                    shortTitle: "Steps", systemImageName: "figure.walk")
        AppShortcut(intent: BatteryIntent(), phrases: ["\(.applicationName) battery"],
                    shortTitle: "Band Battery", systemImageName: "battery.75percent")
    }
}
