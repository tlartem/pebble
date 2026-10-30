import Foundation
import Combine

struct Profile: Codable, Equatable {
    var age: Int?
    var maximumHeartRate: Int?
    var sex: Sex = .unspecified
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        age = try c.decodeIfPresent(Int.self, forKey: .age)
        maximumHeartRate = try c.decodeIfPresent(Int.self, forKey: .maximumHeartRate)
        sex = try c.decodeIfPresent(Sex.self, forKey: .sex) ?? .unspecified
    }
}

struct SavedData: Codable {
    var schema = 1
    var workouts: [WorkoutEntry] = []
    var metrics: [DailyMetric] = []
    var sources: [String: String] = [:]
    var goal = 10000
    var healthReadAt: Date?
    var session: WorkoutSession?
    var alerts = AlertSettings()
    var alertReceipts: [AlertReceipt] = []
    var stepSamples: [StepSample] = []
    var profile = Profile()

    init() {}
    /// Every field is optional on disk so older libraries keep opening.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        workouts = try c.decodeIfPresent([WorkoutEntry].self, forKey: .workouts) ?? []
        metrics = try c.decodeIfPresent([DailyMetric].self, forKey: .metrics) ?? []
        sources = try c.decodeIfPresent([String: String].self, forKey: .sources) ?? [:]
        goal = try c.decodeIfPresent(Int.self, forKey: .goal) ?? 10000
        healthReadAt = try c.decodeIfPresent(Date.self, forKey: .healthReadAt)
        session = try c.decodeIfPresent(WorkoutSession.self, forKey: .session)
        alerts = try c.decodeIfPresent(AlertSettings.self, forKey: .alerts) ?? AlertSettings()
        alertReceipts = try c.decodeIfPresent([AlertReceipt].self, forKey: .alertReceipts) ?? []
        stepSamples = try c.decodeIfPresent([StepSample].self, forKey: .stepSamples) ?? []
        profile = try c.decodeIfPresent(Profile.self, forKey: .profile) ?? Profile()
    }
    var deliveredKeys: Set<String> { Set(alertReceipts.map(\.key)) }
}

final class AppStore: ObservableObject {
    @Published private(set) var data = SavedData()
    @Published var error: String?
    @Published var preview = false
    private var realData: SavedData?
    private let url: URL
    private var loadFailed = false
    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = directory.appendingPathComponent("air-library.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let saved = try JSONDecoder().decode(SavedData.self, from: Data(contentsOf: url))
                guard saved.schema == 1 else { throw CocoaError(.coderReadCorrupt) }
                data = saved
            }
        } catch { self.error = L("Your saved library could not be opened. It has not been overwritten."); loadFailed = true }
    }
    /// Saved with "until first unlock" protection so background alerts can
    /// record receipts while the iPhone is locked.
    @discardableResult func change(_ body: (inout SavedData) -> Void) -> Bool {
        guard !loadFailed || preview else { return false }
        var next = data; body(&next)
        do {
            if !preview { try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            data = next; return true
        } catch { self.error = L("Couldn’t save your changes. Check available iPhone storage."); return false }
    }
    func setPreview(_ enabled: Bool) {
        guard preview != enabled else { return }
        if enabled { realData = data; data = Self.examples(); preview = true }
        else { data = realData ?? SavedData(); realData = nil; preview = false }
    }
    func sourceOptions(_ kind: MetricKind) -> [(id: String, name: String)] {
        var seen = Set<String>()
        return data.metrics.filter { $0.kind == kind }.sorted { $0.sourceName < $1.sourceName }
            .filter { seen.insert($0.sourceID).inserted }.map { ($0.sourceID, $0.sourceName) }
    }
    func points(_ kind: MetricKind) -> [DailyMetric] {
        let candidates = data.metrics.filter { $0.kind == kind }
        let preferred = data.sources[kind.rawValue]
        let source: String?
        if candidates.contains(where: { $0.sourceID == preferred }) { source = preferred }
        else {
            // Default to the source with the most days, never a blend of sources.
            let counts = Dictionary(grouping: candidates, by: \.sourceID).mapValues(\.count)
            source = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        }
        return candidates.filter { $0.sourceID == source }.sorted { $0.date < $1.date }
    }
    static func examples(now: Date = Date()) -> SavedData {
        var data = SavedData(); let cal = Calendar.current
        var seed: UInt64 = 7
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
        for offset in 1...70 {
            let date = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
            let weekend = cal.isDateInWeekend(date)
            let values: [MetricKind: Double] = [
                .restingPulse: 56 + noise() * 4 + (offset < 4 ? 3 : 0),
                .hrvSDNN: 52 * exp(noise() * 0.35) - (offset < 4 ? 6 : 0),
                .sleepHours: 7.1 + noise() * 1.3 + (weekend ? 0.6 : 0),
                .steps: max(2500, 9200 + noise() * 6000 - (weekend ? 1500 : 0)),
                .sleepMidpoint: 3.4 + noise() * 0.9 + (weekend ? 0.8 : 0),
            ]
            for (kind, value) in values {
                data.metrics.append(DailyMetric(kind: kind, date: date, value: value, sourceID: "example", sourceName: "Example data"))
            }
        }
        let activities = ["Run", "Strength", "Ride", "Run", "Yoga"]
        for (index, offset) in [1, 2, 4, 6, 8, 9, 11, 13, 15, 16, 18, 20, 22, 25, 27, 29, 32, 34, 36, 39].enumerated() {
            data.workouts.append(WorkoutEntry(id: UUID(), date: cal.date(byAdding: .day, value: -offset, to: now)!, activity: activities[index % 5], minutes: Double(30 + (index * 7) % 35), effort: 4 + index % 5, note: "", source: "Example data"))
        }
        data.alerts.milestone.enabled = true
        data.alerts.call.enabled = true
        data.profile.age = 34; data.profile.sex = .male
        data.healthReadAt = now
        return data
    }
}
