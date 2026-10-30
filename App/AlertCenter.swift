import Foundation
import UserNotifications
import CallKit
import UIKit
import Combine
import BackgroundTasks

/// Turns phone and band events into band vibrations, iPhone notifications and
/// optional webhooks. Deliveries run one at a time and are journaled first, so
/// a relaunch or repeated reading never replays an alert.
final class AlertCenter: NSObject, ObservableObject, CXCallObserverDelegate, UNUserNotificationCenterDelegate {
    static let refreshTaskID = "com.medpar.air.companion.steps"
    @Published private(set) var lastMessage: String?
    @Published private(set) var nextCheck: Date?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var delivering = false
    /// USB acceptance only: treat calls as enabled for this process.
    var diagnosticCalls = false
    private let calls = CXCallObserver()
    private weak var library: AppStore?
    private weak var band: BandConnection?
    private weak var keepAlive: KeepAlive?
    private var chain: Task<Void, Never>?
    private var checkTimer: Timer?
    private var bag = Set<AnyCancellable>()

    func bind(library: AppStore, band: BandConnection, keepAlive: KeepAlive) {
        guard self.library == nil else { return }
        self.library = library; self.band = band; self.keepAlive = keepAlive
        calls.setDelegate(self, queue: .main)
        UNUserNotificationCenter.current().delegate = self
        band.$activityUpdateID.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, let reading = self.band?.activity else { return }
            self.handle(reading)
        }.store(in: &bag)
        if library.data.alerts.keepAlive { keepAlive.start() }
        scheduleNextCheck()
    }

    private var canWorkInBackground: Bool { keepAlive?.running == true }
    private var isForeground: Bool { UIApplication.shared.applicationState != .background }

    // MARK: Steps

    private func handle(_ reading: ActivityReading) {
        guard let library, !library.preview, let steps = reading.steps else { return }
        let now = Date()
        library.change { data in
            let day = Calendar.current.startOfDay(for: reading.readAt)
            data.metrics.removeAll { $0.kind == .steps && $0.sourceID == "air" && $0.date == day }
            data.metrics.append(DailyMetric(kind: .steps, date: day, value: Double(steps), sourceID: "air", sourceName: "Fitbit Air"))
            data.stepSamples.append(StepSample(date: reading.readAt, steps: steps))
            data.stepSamples.removeAll { now.timeIntervalSince($0.date) > 36 * 3600 }
            data.alertReceipts.removeAll { now.timeIntervalSince($0.date) > 21 * 86400 }
        }
        lastCheck = now
        let data = library.data
        var due = AlertEngine.due(settings: data.alerts, goal: data.goal, steps: steps, readAt: reading.readAt, now: now, delivered: data.deliveredKeys)
        if let move = AlertEngine.moveDue(settings: data.alerts, samples: data.stepSamples, now: now, delivered: data.deliveredKeys) { due.append(move) }
        for item in due { deliver(item, steps: steps) }
        scheduleNextCheck()
    }

    /// Plans the next activity read. With keep-alive on, a timer runs it on
    /// time; otherwise iOS background refresh runs it when it chooses.
    func scheduleNextCheck() {
        checkTimer?.invalidate(); checkTimer = nil
        guard let library, !library.preview else { nextCheck = nil; return }
        let data = library.data
        guard data.alerts.needsStepChecks else { nextCheck = nil; BGTaskScheduler.shared.cancelAllTaskRequests(); return }
        let interval = AlertEngine.nextCheck(settings: data.alerts, goal: data.goal, samples: data.stepSamples, now: Date())
        let date = Date().addingTimeInterval(interval)
        nextCheck = date
        if data.alerts.keepAlive {
            checkTimer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in self?.runCheck { _ in } }
            if let checkTimer { RunLoop.main.add(checkTimer, forMode: .common) }
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = date
        try? BGTaskScheduler.shared.submit(request)
    }

    func runCheck(completion: @escaping (Bool) -> Void) {
        guard let band, let library, !library.preview, library.data.alerts.needsStepChecks else { completion(false); return }
        Task { @MainActor in
            let ready = await band.waitUntilIdle(seconds: 10)
            guard ready else { self.scheduleNextCheck(); completion(false); return }
            let ok = await band.run { band.readActivity() }
            if !ok { self.scheduleNextCheck() }
            completion(ok)
        }
    }

    // MARK: Calls

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard !call.isOutgoing, !call.hasConnected, !call.hasEnded,
              let library, !library.preview, library.data.alerts.call.enabled || diagnosticCalls,
              band?.observingEvents != true, isForeground || canWorkInBackground else { return }
        let key = "call-\(call.uuid.uuidString)"
        guard !library.data.deliveredKeys.contains(key) else { return }
        deliver(DueAlert(event: .call, key: key, settles: [key]), callID: call.uuid)
    }

    // MARK: Delivery

    /// Shortcuts and the in-app test call this. Not journaled; each run is explicit.
    func buzz(_ pattern: BuzzPattern) async -> Bool {
        await withCheckedContinuation { continuation in
            enqueue(label: L("Buzz")) { [weak self] in
                guard let self, let band = self.band, !(self.library?.preview ?? true) else { continuation.resume(returning: false); return }
                let ok = await self.vibrate(band, pattern)
                self.lastMessage = ok ? L("%@ buzz delivered", String(describing: pattern.title)) : L("Band unavailable · try again in a moment")
                continuation.resume(returning: ok)
            }
        }
    }

    private func deliver(_ item: DueAlert, steps: Int? = nil, callID: UUID? = nil) {
        guard let library else { return }
        var rule = library.data.alerts.rule(item.event)
        if item.event == .call && diagnosticCalls { rule.enabled = true }
        let receipts = item.settles.map { AlertReceipt(date: Date(), event: item.event, key: $0, outcome: "Pending") }
        // Journal first: an interrupted delivery is never replayed.
        guard library.change({ $0.alertReceipts.append(contentsOf: receipts) }) else { return }
        enqueue(label: item.event.title) { [weak self] in
            guard let self, let band = self.band, let library = self.library else { return }
            if let callID, !self.calls.calls.contains(where: { $0.uuid == callID && !$0.hasConnected && !$0.hasEnded }) { return }
            var outcome: [String] = []
            if rule.notifyPhone, item.event != .call { await self.notify(item.event, steps: steps, goal: library.data.goal) ; outcome.append("iPhone") }
            if rule.webhook { self.postWebhook(item.event, steps: steps, goal: library.data.goal); outcome.append("webhook") }
            if rule.enabled {
                let ok = await self.vibrate(band, rule.pattern)
                outcome.append(ok ? "band" : "band unavailable")
            }
            let summary = "\(item.event.title) · " + (outcome.isEmpty ? "recorded" : outcome.joined(separator: ", "))
            self.lastMessage = L(item.event.title) + " · " + (outcome.isEmpty ? L("recorded") : outcome.map { L($0) }.joined(separator: ", "))
            library.change { data in
                for index in data.alertReceipts.indices where item.settles.contains(data.alertReceipts[index].key) { data.alertReceipts[index].outcome = summary }
            }
        }
    }

    private func enqueue(label: String, _ work: @escaping () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            // Keep the process alive through connection, pattern and restore.
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask(withName: L("Pebble alert: %@", String(describing: label))) { UIApplication.shared.endBackgroundTask(task); task = .invalid }
            self.delivering = true
            await work()
            self.delivering = false
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    private func vibrate(_ band: BandConnection, _ pattern: BuzzPattern) async -> Bool {
        guard await band.waitUntilIdle(seconds: 20) else { return false }
        return await band.vibrate(pattern)
    }

    private func notify(_ event: AlertEvent, steps: Int?, goal: Int) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        switch event {
        case .goal: content.title = L("Goal reached"); content.body = L("%@ steps today.", String(describing: goal.formatted()))
        case .milestone: content.title = L("%@ steps", String(describing: (steps ?? 0).formatted())); content.body = L("Another milestone today.")
        case .move: content.title = L("Time to move"); content.body = L("A short walk breaks up a long sitting stretch.")
        case .call, .shortcut: return
        }
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "pebble-\(event.rawValue)-\(UUID().uuidString)", content: content, trigger: nil))
    }

    private func postWebhook(_ event: AlertEvent, steps: Int?, goal: Int) {
        guard let raw = library?.data.alerts.webhookURL, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["event": event.rawValue, "time": ISO8601DateFormatter().string(from: Date()), "goal": goal, "source": "pebble"]
        if let steps { body["steps"] = steps }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request).resume()
    }

    func requestNotificationPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
