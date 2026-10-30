import Foundation
import HealthKit
import Combine

/// Read-only Apple Health import. Each source/device stays separate; nothing
/// is written to Health. Empty results keep previous history because Health
/// does not reveal whether access was denied or no data exists.
final class HealthImport: ObservableObject {
    @Published var busy = false
    @Published var message: String?
    private let health = HKHealthStore()
    private let resting = HKQuantityType(.restingHeartRate)
    private let variability = HKQuantityType(.heartRateVariabilitySDNN)
    private let stepCount = HKQuantityType(.stepCount)
    private let sleep = HKCategoryType(.sleepAnalysis)
    private let birthday = HKCharacteristicType(.dateOfBirth)

    func refresh(into library: AppStore) {
        guard !busy, !library.preview else { return }
        guard HKHealthStore.isHealthDataAvailable() else { message = L("Apple Health isn’t available on this device."); return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await health.requestAuthorization(toShare: [], read: [resting, variability, stepCount, sleep, birthday, HKObjectType.workoutType()])
                let start = Calendar.current.date(byAdding: .day, value: -90, to: Calendar.current.startOfDay(for: Date()))!
                async let pulseSamples = samples(resting, since: start)
                async let hrvSamples = samples(variability, since: start)
                async let sleepSamples = samples(sleep, since: start)
                async let workoutSamples = samples(HKObjectType.workoutType(), since: start)
                async let stepDays = dailySteps(since: start)
                let (pulse, hrv, nights, sessions, steps) = try await (pulseSamples, hrvSamples, sleepSamples, workoutSamples, stepDays)
                let metrics = quantityDays(pulse, kind: .restingPulse, unit: HKUnit.count().unitDivided(by: .minute()))
                    + quantityDays(hrv, kind: .hrvSDNN, unit: .secondUnit(with: .milli)) + sleepDays(nights) + steps
                let workouts = sessions.compactMap(workoutEntry)
                let age = (try? health.dateOfBirthComponents()).flatMap { components -> Int? in
                    guard let date = Calendar.current.date(from: components) else { return nil }
                    return Calendar.current.dateComponents([.year], from: date, to: Date()).year
                }
                guard !metrics.isEmpty || !workouts.isEmpty || age != nil else {
                    message = L("Nothing readable yet. Check Pebble’s access in the Health app.")
                    return
                }
                let importedKinds = Set(metrics.map(\.kind))
                let saved = library.change { data in
                    // Replace this bounded window per metric kind; never merge sources.
                    data.metrics.removeAll { $0.sourceID != "air" && importedKinds.contains($0.kind) }
                    data.metrics += metrics
                    let existing = Dictionary(uniqueKeysWithValues: data.workouts.map { ($0.id, $0) })
                    let importedIDs = Set(workouts.map(\.id))
                    data.workouts.removeAll { importedIDs.contains($0.id) }
                    data.workouts += workouts.map { workout in
                        var entry = workout
                        if let old = existing[entry.id] { entry.effort = old.effort; entry.note = old.note }
                        return entry
                    }
                    if data.profile.age == nil, let age, (10...110).contains(age) { data.profile.age = age }
                    data.healthReadAt = Date()
                }
                if saved { message = L("Updated from Apple Health.") }
            } catch { message = L("Apple Health import didn’t finish. Your history is unchanged.") }
        }
    }

    private func workoutEntry(_ sample: HKSample) -> WorkoutEntry? {
        guard let workout = sample as? HKWorkout, workout.duration > 0 else { return nil }
        let name: String
        switch workout.workoutActivityType {
        case .running: name = "Run"
        case .walking: name = "Walk"
        case .hiking: name = "Hike"
        case .cycling: name = "Ride"
        case .swimming: name = "Swim"
        case .traditionalStrengthTraining, .functionalStrengthTraining: name = "Strength"
        case .highIntensityIntervalTraining: name = "Intervals"
        case .yoga: name = "Yoga"
        default: name = "Workout"
        }
        return WorkoutEntry(id: workout.uuid, date: workout.startDate, activity: name, minutes: workout.duration / 60, effort: nil, note: "", source: workout.sourceRevision.source.name)
    }

    private func samples(_ type: HKSampleType, since start: Date) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate), limit: 20001, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else if (samples?.count ?? 0) > 20000 { continuation.resume(throwing: CocoaError(.fileReadTooLarge)) }
                else { continuation.resume(returning: samples ?? []) }
            }
            health.execute(query)
        }
    }

    /// Daily step sums per source, using Health's own de-duplicated statistics.
    private func dailySteps(since start: Date) async throws -> [DailyMetric] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: stepCount, quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: Date()),
                                                    options: [.cumulativeSum, .separateBySource], anchorDate: start, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error); return }
                var result: [DailyMetric] = []
                let today = Calendar.current.startOfDay(for: Date())
                collection?.enumerateStatistics(from: start, to: Date()) { statistics, _ in
                    // Today is still in progress; only completed days enter trends.
                    guard statistics.startDate < today else { return }
                    for source in statistics.sources ?? [] {
                        guard let sum = statistics.sumQuantity(for: source)?.doubleValue(for: .count()), sum > 0 else { continue }
                        result.append(DailyMetric(kind: .steps, date: statistics.startDate, value: sum, sourceID: "health:" + source.bundleIdentifier, sourceName: source.name))
                    }
                }
                continuation.resume(returning: result)
            }
            health.execute(query)
        }
    }

    private func sourceID(_ sample: HKSample) -> String {
        // Keep devices separate even when the writing app is the same.
        sample.sourceRevision.source.bundleIdentifier + ":" + (sample.device?.localIdentifier ?? sample.device?.name ?? "default")
    }
    private func sourceName(_ sample: HKSample) -> String {
        sample.sourceRevision.source.name + (sample.device?.name.map { " · \($0)" } ?? "")
    }
    private func quantityDays(_ samples: [HKSample], kind: MetricKind, unit: HKUnit) -> [DailyMetric] {
        let groups = Dictionary(grouping: samples.compactMap { $0 as? HKQuantitySample }) {
            sourceID($0) + ":" + String(Calendar.current.startOfDay(for: $0.startDate).timeIntervalSince1970)
        }
        return groups.values.compactMap { group in
            guard let first = group.first, let mean = FitnessMath.mean(group.map { $0.quantity.doubleValue(for: unit) }.filter { $0 > 0 }) else { return nil }
            return DailyMetric(kind: kind, date: Calendar.current.startOfDay(for: first.startDate), value: mean, sourceID: sourceID(first), sourceName: sourceName(first))
        }
    }
    private func sleepDays(_ samples: [HKSample]) -> [DailyMetric] {
        let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        let groups = Dictionary(grouping: samples.compactMap { $0 as? HKCategorySample }.filter { asleep.contains($0.value) }, by: { sourceID($0) })
        return groups.values.flatMap { group -> [DailyMetric] in
            guard let sample = group.first else { return [] }
            let intervals = group.filter { $0.endDate > $0.startDate }.map { DateInterval(start: $0.startDate, end: $0.endDate) }
            let durations = FitnessMath.sleepByMorning(intervals).map { date, duration in
                DailyMetric(kind: .sleepHours, date: date, value: duration / 3600, sourceID: sourceID(sample), sourceName: sourceName(sample))
            }
            let midpoints = FitnessMath.sleepMidpoints(intervals).map { date, hours in
                DailyMetric(kind: .sleepMidpoint, date: date, value: hours, sourceID: sourceID(sample), sourceName: sourceName(sample))
            }
            return durations + midpoints
        }
    }
}
