import SwiftUI
import BackgroundTasks

/// One instance of each service, shared with App Intents and background tasks.
final class Services {
    static let shared = Services()
    let band = BandConnection()
    let library = AppStore()
    let health = HealthImport()
    let alerts = AlertCenter()
    let keepAlive = KeepAlive()
    let liveHeart = LiveHeartRate()
    private init() { alerts.bind(library: library, band: band, keepAlive: keepAlive) }
}

@main
struct PebbleApp: App {
    private let services: Services
    @Environment(\.scenePhase) private var scene
    @State private var tab = 0

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AlertCenter.refreshTaskID, using: .main) { task in
            let services = Services.shared
            task.expirationHandler = { services.band.stop() }
            services.alerts.runCheck { ok in task.setTaskCompleted(success: ok) }
        }
        // Registration must precede the first scheduling in Services.
        services = Services.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView(tab: $tab)
                .environmentObject(services.band)
                .environmentObject(services.library)
                .environmentObject(services.health)
                .environmentObject(services.alerts)
                .environmentObject(services.keepAlive)
                .environmentObject(services.liveHeart)
                .onAppear(perform: launchArguments)
                .onChange(of: scene) { _, state in
                    let band = services.band
                    switch state {
                    case .active:
                        band.refreshKeys()
                        services.alerts.scheduleNextCheck()
                        let stale = band.lastRead.map { Date().timeIntervalSince($0) > 600 } ?? true
                        if stale, band.canStart, !services.library.preview, !Self.diagnostic { band.start() }
                    case .background:
                        // With keep-alive off, never hold the band from Google Health.
                        if !services.library.data.alerts.keepAlive { band.stop() }
                    default: break
                    }
                }
                .onChange(of: services.band.active) { _, active in UIApplication.shared.isIdleTimerDisabled = active && Self.diagnostic }
        }
    }

    private static var diagnostic: Bool { ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--diagnostic") } }

    /// USB acceptance controls (`devicectl … process launch -- --diagnostic …`).
    private func launchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        let band = services.band
        if let index = arguments.firstIndex(of: "--tab"), arguments.count > index + 1 { tab = Int(arguments[index + 1]) ?? 0 }
        if arguments.contains("--preview") { services.library.setPreview(true); band.setPreview(true); return }
        if arguments.contains("--diagnostic-refresh") { band.enableDiagnosticCapture(); band.start(); return }
        guard let index = arguments.firstIndex(of: "--diagnostic"), arguments.count > index + 1 else { return }
        let operation = arguments[index + 1], argument = arguments.count > index + 2 ? arguments[index + 2] : nil
        if operation == "background-check" {
            // Starts keep-alive for this process only (saved settings unchanged)
            // and reads activity once, 60 s later, to prove background access.
            services.keepAlive.start()
            band.enableDiagnosticCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { band.readActivity() }
            return
        }
        if operation == "call-check" {
            // Keep-alive and the call alert for this process only; a CallKit
            // test call rings after the given delay (default 45 s) for 25 s.
            services.keepAlive.start()
            services.alerts.diagnosticCalls = true
            band.enableDiagnosticCapture()
            TestCall.shared.ring(after: argument.flatMap(Double.init) ?? 45, for: 25)
            return
        }
        if operation == "pattern", let pattern = argument.flatMap(BuzzPattern.init(rawValue:)) {
            band.enableDiagnosticCapture(); band.vibrate(pattern); return
        }
        band.runDiagnostic(operation, alarmID: argument.flatMap(UInt64.init))
    }
}

struct RootView: View {
    @Binding var tab: Int
    var body: some View {
        TabView(selection: $tab) {
            TodayScreen().tabItem { Label(L("Today"), systemImage: "circle.dotted.circle") }.tag(0)
            AlarmsScreen().tabItem { Label(L("Alarms"), systemImage: "alarm") }.tag(1)
            TrendsScreen().tabItem { Label(L("Trends"), systemImage: "chart.line.uptrend.xyaxis") }.tag(2)
            BandScreen().tabItem { Label(L("Band"), image: "PebbleTab") }.tag(3)
        }
    }
}
