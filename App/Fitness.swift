import Foundation

enum Sex: String, Codable, CaseIterable, Identifiable { case female, male, unspecified; var id: String { rawValue } }

enum MetricKind: String, Codable, CaseIterable, Identifiable {
    case steps, sleepHours, restingPulse, hrvSDNN, sleepMidpoint
    var id: String { rawValue }
    var title: String {
        switch self {
        case .restingPulse: return "Resting heart rate"
        case .hrvSDNN: return "Heart rate variability"
        case .sleepHours: return "Sleep"
        case .steps: return "Steps"
        case .sleepMidpoint: return "Sleep timing"
        }
    }
    var short: String {
        switch self {
        case .restingPulse: return "Resting HR"
        case .hrvSDNN: return "HRV"
        case .sleepHours: return "Sleep"
        case .steps: return "Steps"
        case .sleepMidpoint: return "Timing"
        }
    }
    var unit: String {
        switch self {
        case .restingPulse: return "bpm"
        case .hrvSDNN: return "ms"
        case .sleepHours: return "h"
        case .steps: return "steps"
        case .sleepMidpoint: return "midpoint"
        }
    }
    var symbol: String {
        switch self {
        case .restingPulse: return "heart"
        case .hrvSDNN: return "waveform.path.ecg"
        case .sleepHours: return "bed.double"
        case .steps: return "figure.walk"
        case .sleepMidpoint: return "moon.stars"
        }
    }
    var decimals: Int { self == .sleepHours ? 1 : 0 }
    /// Whether larger values are generally the favourable direction.
    var higherIsBetter: Bool? {
        switch self {
        case .hrvSDNN, .steps, .sleepHours: return true
        case .restingPulse: return false
        case .sleepMidpoint: return nil
        }
    }
}

struct DailyMetric: Codable, Identifiable {
    var id: String { "\(kind.rawValue)-\(sourceID)-\(date.timeIntervalSince1970)" }
    let kind: MetricKind
    let date: Date
    let value: Double
    let sourceID: String
    let sourceName: String
}

struct WorkoutEntry: Codable, Identifiable {
    let id: UUID
    var date: Date
    var activity: String
    var minutes: Double
    var effort: Int?
    var note: String
    var source: String
    var averageHeartRate: Int? = nil
    var zoneMinutes: [Double]? = nil
    var load: Double? { effort.map { minutes * Double($0) } }
    var valid: Bool { minutes.isFinite && minutes > 0 && minutes <= 1440 && (effort == nil || (0...10).contains(effort!)) && note.count <= 2000 }
}

struct MetricTrend {
    let recent: Double?
    let baseline: Double?
    let recentDays: Int
    let baselineDays: Int
    var delta: Double? { guard recentDays >= 4, baselineDays >= 14, let recent, let baseline else { return nil }; return recent - baseline }
}

/// A recent average compared with the person's own usual range.
struct BodySignal {
    enum Position { case below, within, above }
    let kind: MetricKind
    let recent: Double
    let low: Double
    let high: Double
    let recentDays: Int
    let baselineDays: Int
    var position: Position { recent < low ? .below : recent > high ? .above : .within }
    /// Position at display precision, so "57 vs 55–57" never reads as outside.
    func shown(_ decimals: Int) -> Position {
        let scale = pow(10, Double(decimals))
        let r = (recent * scale).rounded(), l = (low * scale).rounded(), h = (high * scale).rounded()
        return r < l ? .below : r > h ? .above : .within
    }
}

struct TrainingState: Identifiable {
    var id: Date { date }
    let date: Date
    let load: Double
    let fitness: Double
    let fatigue: Double
    var form: Double { fitness - fatigue }
}

enum FitnessMath {
    static func mean(_ values: [Double]) -> Double? {
        let values = values.filter(\.isFinite)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    static func standardDeviation(_ values: [Double]) -> Double? {
        let values = values.filter(\.isFinite)
        guard values.count >= 2, let m = mean(values) else { return nil }
        return (values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(values.count - 1)).squareRoot()
    }

    /// Seven completed local days versus the preceding 28. Missing days are not zero.
    static func trend(_ values: [DailyMetric], now: Date = Date(), calendar: Calendar = .current) -> MetricTrend {
        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -7, to: today)!
        let baselineStart = calendar.date(byAdding: .day, value: -35, to: today)!
        let recent = values.filter { $0.date >= recentStart && $0.date < today }
        let baseline = values.filter { $0.date >= baselineStart && $0.date < recentStart }
        return MetricTrend(recent: mean(recent.map(\.value)), baseline: mean(baseline.map(\.value)), recentDays: Set(recent.map { calendar.startOfDay(for: $0.date) }).count, baselineDays: Set(baseline.map { calendar.startOfDay(for: $0.date) }).count)
    }

    /// Usual range from the 60 days before the recent week.
    /// HRV is log-transformed and uses ±0.5 SD, the "smallest worthwhile change"
    /// used for rolling HRV monitoring (Plews et al. 2013; Buchheit 2014).
    /// Resting heart rate and sleep use ±1 SD of the person's own daily values.
    static func signal(_ kind: MetricKind, _ values: [DailyMetric], now: Date = Date(), calendar: Calendar = .current) -> BodySignal? {
        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -7, to: today)!
        let baselineStart = calendar.date(byAdding: .day, value: -67, to: today)!
        let logScale = kind == .hrvSDNN
        func scale(_ v: Double) -> Double { logScale ? log(v) : v }
        func unscale(_ v: Double) -> Double { logScale ? exp(v) : v }
        let recent = values.filter { $0.date >= recentStart && $0.date < today && $0.value > 0 }
        let baseline = values.filter { $0.date >= baselineStart && $0.date < recentStart && $0.value > 0 }
        let recentDays = Set(recent.map { calendar.startOfDay(for: $0.date) }).count
        let baselineDays = Set(baseline.map { calendar.startOfDay(for: $0.date) }).count
        guard recentDays >= 4, baselineDays >= 14,
              let r = mean(recent.map { scale($0.value) }), let m = mean(baseline.map { scale($0.value) }),
              let sd = standardDeviation(baseline.map { scale($0.value) }) else { return nil }
        let width = (logScale ? 0.5 : 1.0) * sd
        return BodySignal(kind: kind, recent: unscale(r), low: unscale(m - width), high: unscale(m + width), recentDays: recentDays, baselineDays: baselineDays)
    }

    static func mergedDuration(_ intervals: [DateInterval]) -> TimeInterval { merged(intervals).map(\.duration).reduce(0, +) }
    static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        let ordered = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return [] }
        var result: [DateInterval] = []
        for interval in ordered.dropFirst() {
            if interval.start <= current.end { current = DateInterval(start: current.start, end: max(current.end, interval.end)) }
            else { result.append(current); current = interval }
        }
        return result + [current]
    }
    /// Groups asleep intervals into noon-to-noon windows keyed by the morning date.
    static func sleepWindows(_ intervals: [DateInterval], calendar: Calendar = .current) -> [Date: [DateInterval]] {
        var bins: [Date: [DateInterval]] = [:]
        for interval in intervals where interval.duration > 0 {
            var cursor = interval.start
            while cursor < interval.end {
                let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: cursor)!
                let start = cursor < noon ? calendar.date(byAdding: .day, value: -1, to: noon)! : noon
                let boundary = calendar.date(byAdding: .day, value: 1, to: start)!
                let end = min(boundary, interval.end)
                guard end > cursor else { break }
                bins[calendar.startOfDay(for: boundary), default: []].append(DateInterval(start: cursor, end: end))
                cursor = end
            }
        }
        return bins
    }
    static func sleepByMorning(_ intervals: [DateInterval], calendar: Calendar = .current) -> [Date: TimeInterval] {
        sleepWindows(intervals, calendar: calendar).mapValues(mergedDuration)
    }
    /// Midpoint of the main sleep episode (blocks closer than 60 minutes are
    /// joined), in hours relative to local midnight of the morning: -0.5 is 23:30.
    static func sleepMidpoints(_ intervals: [DateInterval], calendar: Calendar = .current) -> [Date: Double] {
        sleepWindows(intervals, calendar: calendar).compactMapValues { blocks in
            var episodes: [DateInterval] = []
            for block in merged(blocks) {
                if let last = episodes.last, block.start.timeIntervalSince(last.end) < 3600 {
                    episodes[episodes.count - 1] = DateInterval(start: last.start, end: block.end)
                } else { episodes.append(block) }
            }
            guard let main = episodes.max(by: { $0.duration < $1.duration }), main.duration >= 3 * 3600 else { return nil }
            let midpoint = main.start.addingTimeInterval(main.duration / 2)
            let midnight = calendar.startOfDay(for: main.end)
            return midpoint.timeIntervalSince(midnight) / 3600
        }
    }
    /// Night-to-night variability of the sleep midpoint (minutes, SD). Lower is
    /// more regular. Irregular timing is linked to poorer outcomes independent
    /// of duration (Phillips et al. 2017; Windred et al. 2024).
    static func regularity(_ midpoints: [DailyMetric], now: Date = Date(), calendar: Calendar = .current) -> Double? {
        let start = calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: now))!
        let recent = midpoints.filter { $0.date >= start }
        guard recent.count >= 5 else { return nil }
        return standardDeviation(recent.map(\.value)).map { $0 * 60 }
    }

    static func weeklyLoad(_ workouts: [WorkoutEntry], now: Date = Date(), calendar: Calendar = .current) -> Double {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        return workouts.filter { $0.date >= start && $0.date <= now }.compactMap(\.load).reduce(0, +)
    }
    /// Banister impulse-response model on session-RPE load (Banister et al. 1975;
    /// Foster et al. 2001). Fitness and fatigue are exponentially weighted daily
    /// loads with 42- and 7-day time constants; form is their difference.
    static func training(_ workouts: [WorkoutEntry], days: Int = 120, now: Date = Date(), calendar: Calendar = .current) -> [TrainingState] {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        var daily: [Date: Double] = [:]
        for workout in workouts { if let load = workout.load { daily[calendar.startOfDay(for: workout.date), default: 0] += load } }
        let kFitness = 1 - exp(-1.0 / 42), kFatigue = 1 - exp(-1.0 / 7)
        var fitness = 0.0, fatigue = 0.0
        var result: [TrainingState] = []
        var day = start
        while day <= today {
            let load = daily[day] ?? 0
            fitness += (load - fitness) * kFitness
            fatigue += (load - fatigue) * kFatigue
            result.append(TrainingState(date: day, load: load, fitness: fitness, fatigue: fatigue))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    /// Age-predicted maximum heart rate (Tanaka, Monahan & Seals 2001).
    static func maximumHeartRate(age: Int) -> Double { 208 - 0.7 * Double(age) }
    /// Heart-rate-ratio VO₂max estimate, ml/kg/min (Uth et al. 2004). An estimate
    /// with roughly ±10–15% individual error, not a laboratory test.
    static func cardioFitness(maximum: Double, resting: Double) -> Double? {
        guard resting >= 30, resting < maximum else { return nil }
        return 15.3 * maximum / resting
    }
    /// Heart-rate-reserve (Karvonen) zone floors at 50/60/70/80/90% HRR.
    static func zoneFloors(maximum: Double, resting: Double) -> [Double] {
        [0.5, 0.6, 0.7, 0.8, 0.9].map { resting + $0 * (maximum - resting) }
    }
    static func zone(for pulse: Double, floors: [Double]) -> Int? {
        guard let first = floors.first, pulse >= first else { return nil }
        return floors.lastIndex(where: { pulse >= $0 })
    }
    /// Edwards' summated-heart-rate-zone load: minutes in zone 1–5 weighted 1–5.
    static func edwardsLoad(_ zoneMinutes: [Double]) -> Double {
        zoneMinutes.enumerated().map { Double($0.offset + 1) * $0.element }.reduce(0, +)
    }
    /// About 100 steps/min marks moderate-intensity walking in adults
    /// (Tudor-Locke et al. 2018, 2019).
    static func walkingMinutes(forSteps steps: Int) -> Int { Int((Double(max(0, steps)) / 100).rounded(.up)) }
    /// Root mean square of successive RR differences, in milliseconds.
    static func rmssd(_ rr: [Double]) -> Double? {
        let clean = rr.filter { (300...2000).contains($0) }
        guard clean.count >= 10 else { return nil }
        let diffs = zip(clean.dropFirst(), clean).map { ($0 - $1) * ($0 - $1) }
        return (diffs.reduce(0, +) / Double(diffs.count)).squareRoot()
    }

    // MARK: Advanced training load

    /// Exponentially weighted daily load series with the given time constant,
    /// gap-aware (missing days decay toward zero, never skipped).
    static func ewmaDaily(_ workouts: [WorkoutEntry], timeConstant: Double, days: Int, now: Date = Date(), calendar: Calendar = .current) -> [(date: Date, value: Double)] {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        var daily: [Date: Double] = [:]
        for workout in workouts { if let load = workout.load { daily[calendar.startOfDay(for: workout.date), default: 0] += load } }
        let k = 1 - exp(-1.0 / timeConstant)
        var series: [Double] = []
        var day = start
        while day <= today { series.append(daily[day] ?? 0); day = calendar.date(byAdding: .day, value: 1, to: day)! }
        // Seed with the window mean so the ratio isn't biased by a cold start.
        var value = mean(series) ?? 0
        var result: [(Date, Double)] = []
        day = start
        for load in series { value += (load - value) * k; result.append((day, value)); day = calendar.date(byAdding: .day, value: 1, to: day)! }
        return result
    }

    /// Acute:chronic workload ratio, EWMA method (Williams et al., 2017): acute
    /// 7-day over chronic 28-day exponentially weighted load. The 0.8–1.3 band is
    /// the commonly cited "sweet spot"; the ratio is debated (Impellizzeri 2020)
    /// and shown here as context, not a rule.
    struct WorkloadRatio { let acute: Double; let chronic: Double; let ratio: Double?
        var zone: String { guard let ratio else { return "building baseline" }
            return ratio < 0.8 ? "detraining" : ratio <= 1.3 ? "balanced" : ratio <= 1.5 ? "high" : "spike" } }
    static func workloadRatio(_ workouts: [WorkoutEntry], now: Date = Date(), calendar: Calendar = .current) -> WorkloadRatio {
        let acute = ewmaDaily(workouts, timeConstant: 7, days: 28, now: now, calendar: calendar).last?.value ?? 0
        let chronic = ewmaDaily(workouts, timeConstant: 28, days: 42, now: now, calendar: calendar).last?.value ?? 0
        // The ratio is only meaningful with a few weeks of history (Williams 2017).
        let chronicStart = calendar.date(byAdding: .day, value: -28, to: calendar.startOfDay(for: now))!
        let trainingDays = Set(workouts.filter { $0.load != nil && $0.date >= chronicStart }.map { calendar.startOfDay(for: $0.date) }).count
        return WorkloadRatio(acute: acute, chronic: chronic, ratio: trainingDays >= 8 && chronic > 0 ? acute / chronic : nil)
    }
    /// Week-over-week change in total load, as a percentage. Large positive jumps
    /// (>~50%) are a classic overload flag.
    static func weeklyRamp(_ workouts: [WorkoutEntry], now: Date = Date(), calendar: Calendar = .current) -> Double? {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek)!
        func load(_ from: Date, _ to: Date) -> Double { workouts.filter { $0.date >= from && $0.date < to }.compactMap(\.load).reduce(0, +) }
        let previous = load(lastWeek, thisWeek)
        guard previous > 0 else { return nil }
        return (load(thisWeek, calendar.date(byAdding: .weekOfYear, value: 1, to: thisWeek)!) - previous) / previous * 100
    }

    // MARK: HRV adaptation

    static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard let m = mean(values), m > 0, let sd = standardDeviation(values) else { return nil }
        return sd / m * 100
    }
    /// Rolling 7-day coefficient of variation of HRV. A rising CV alongside a
    /// falling mean indicates poorer adaptation (Plews et al., 2012).
    static func hrvVariation(_ points: [DailyMetric], now: Date = Date(), calendar: Calendar = .current) -> Double? {
        let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))!
        let recent = points.filter { $0.date >= start && $0.value > 0 }
        guard recent.count >= 4 else { return nil }
        return coefficientOfVariation(recent.map(\.value))
    }

    // MARK: Circadian

    /// Social jetlag: absolute difference between average free-day (weekend) and
    /// work-day (weekday) sleep midpoints, in hours (Wittmann et al., 2006).
    static func socialJetlag(_ midpoints: [DailyMetric], now: Date = Date(), calendar: Calendar = .current) -> Double? {
        let start = calendar.date(byAdding: .day, value: -28, to: calendar.startOfDay(for: now))!
        let recent = midpoints.filter { $0.date >= start }
        let weekend = recent.filter { calendar.isDateInWeekend($0.date) }.map(\.value)
        let weekday = recent.filter { !calendar.isDateInWeekend($0.date) }.map(\.value)
        guard weekend.count >= 2, weekday.count >= 3, let we = mean(weekend), let wd = mean(weekday) else { return nil }
        return abs(we - wd)
    }

    // MARK: Cardiorespiratory fitness norms

    /// Coarse VO₂max percentile category from Cooper Institute / ACSM norms,
    /// by sex and age decade. Returns a label and an approximate percentile.
    static func cardioCategory(vo2: Double, age: Int, sex: Sex) -> (label: String, percentile: Int)? {
        guard sex != .unspecified, (20...79).contains(age) else { return nil }
        // Cut points (ml/kg/min) at the 20th/40th/60th/80th percentiles.
        let male: [(Int, [Double])] = [(29, [41, 44, 48, 52]), (39, [39, 42, 45, 50]), (49, [36, 40, 43, 48]), (59, [33, 36, 40, 44]), (79, [29, 32, 36, 41])]
        let female: [(Int, [Double])] = [(29, [35, 38, 42, 47]), (39, [33, 36, 40, 45]), (49, [31, 34, 37, 42]), (59, [28, 31, 34, 39]), (79, [25, 28, 31, 36])]
        let table = sex == .male ? male : female
        guard let cuts = table.first(where: { age <= $0.0 })?.1 else { return nil }
        let labels = ["Very low", "Low", "Fair", "Good", "Excellent"]
        let percentiles = [10, 30, 50, 70, 90]
        let index = cuts.filter { vo2 >= $0 }.count
        return (labels[index], percentiles[index])
    }

    // MARK: Daily readiness (transparent heuristic)

    struct ReadinessInput { let hrv: BodySignal?; let rhr: BodySignal?; let sleepHours: Double?; let sleepNeed: Double; let regularityMinutes: Double? }
    struct Readiness {
        let score: Int
        let components: [(name: String, score: Int, detail: String)]
        var band: String { score >= 67 ? "High" : score >= 34 ? "Balanced" : "Low" }
    }
    /// A transparent 0–100 recovery heuristic from the person's own baselines.
    /// Weights: HRV 40, resting HR 25, sleep duration 25, regularity 10 — the
    /// standard HRV-led recovery model (Plews 2013; Buchheit 2014). It rescales
    /// to whatever inputs are present, shows each part, and is not a diagnosis.
    static func readiness(_ input: ReadinessInput) -> Readiness? {
        func sub(_ signal: BodySignal, higherBetter: Bool) -> Int {
            let span = max(signal.high - signal.low, 0.0001)
            let mid = (signal.high + signal.low) / 2
            let z = (signal.recent - mid) / (span / 2)       // ±1 at range edge
            let directed = higherBetter ? z : -z
            return Int((50 + directed * 30).rounded().clamped(to: 0...100))
        }
        var parts: [(String, Int, Double, String)] = []  // name, score, weight, detail
        if let hrv = input.hrv { parts.append(("HRV", sub(hrv, higherBetter: true), 40, L("%@ vs %@–%@ ms", String(describing: Int(hrv.recent)), String(describing: Int(hrv.low)), String(describing: Int(hrv.high))))) }
        if let rhr = input.rhr { parts.append(("Resting HR", sub(rhr, higherBetter: false), 25, L("%@ vs %@–%@ bpm", String(describing: Int(rhr.recent)), String(describing: Int(rhr.low)), String(describing: Int(rhr.high))))) }
        if let hours = input.sleepHours {
            let score = Int((hours / input.sleepNeed * 85).rounded().clamped(to: 0...100))
            parts.append(("Sleep", score, 25, String(format: L("%.1f h of ~%.0f h"), hours, input.sleepNeed)))
        }
        if let reg = input.regularityMinutes {
            let score = Int((100 - reg).clamped(to: 0...100))   // 0 min SD = 100, 100 min = 0
            parts.append(("Regularity", score, 10, L("±%@ min midpoint", String(describing: Int(reg)))))
        }
        guard parts.count >= 2, parts.contains(where: { $0.0 == "HRV" || $0.0 == "Resting HR" }) else { return nil }
        let totalWeight = parts.map(\.2).reduce(0, +)
        let score = Int((parts.map { Double($0.1) * $0.2 }.reduce(0, +) / totalWeight).rounded())
        return Readiness(score: score, components: parts.map { ($0.0, $0.1, $0.3) })
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

struct WorkoutSession: Codable {
    let startedAt: Date
    var resumedAt: Date?
    var accumulated: TimeInterval
    var activity: String? = nil
    init(now: Date = Date(), activity: String? = nil) { startedAt = now; resumedAt = now; accumulated = 0; self.activity = activity }
    func elapsed(at now: Date) -> TimeInterval { accumulated + (resumedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0) }
    var paused: Bool { resumedAt == nil }
    mutating func pause(at now: Date) { accumulated = elapsed(at: now); resumedAt = nil }
    mutating func resume(at now: Date) { if resumedAt == nil { resumedAt = now } }
}
