import SwiftUI

extension AppStore {
    /// Assembles today's readiness from the person's own baselines.
    func readiness(now: Date = Date()) -> FitnessMath.Readiness? {
        let hrv = FitnessMath.signal(.hrvSDNN, points(.hrvSDNN), now: now)
        let rhr = FitnessMath.signal(.restingPulse, points(.restingPulse), now: now)
        let sleep = points(.sleepHours)
        let recentSleep = sleep.last.flatMap { latest -> Double? in
            let days = Calendar.current.dateComponents([.day], from: latest.date, to: now).day ?? 99
            return days <= 2 ? latest.value : nil
        }
        let need = (FitnessMath.mean(sleep.suffix(60).map(\.value)) ?? 8).clampedDouble(6, 9)
        let regularity = FitnessMath.regularity(points(.sleepMidpoint), now: now)
        return FitnessMath.readiness(.init(hrv: hrv, rhr: rhr, sleepHours: recentSleep, sleepNeed: need, regularityMinutes: regularity))
    }
}

private extension Double { func clampedDouble(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) } }

struct ReadinessCard: View {
    @EnvironmentObject private var library: AppStore
    @Binding var methods: Bool
    var body: some View {
        if let readiness = library.readiness() {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(L("Readiness"))
                    Spacer()
                    Button { methods = true } label: { Image(systemName: "info.circle").foregroundStyle(Tone.ink3) }
                        .accessibilityLabel(L("How readiness is calculated"))
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(readiness.score)").font(.figure(64)).monospacedDigit().foregroundStyle(color(readiness.band))
                        .contentTransition(.numericText(value: Double(readiness.score)))
                    Text(L(readiness.band)).font(.title3.weight(.semibold)).foregroundStyle(color(readiness.band))
                    Spacer()
                }.padding(.top, 4)
                VStack(spacing: 10) {
                    ForEach(readiness.components, id: \.name) { part in
                        HStack(spacing: 10) {
                            Text(L(part.name)).font(.subheadline).frame(width: 92, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Tone.sunken)
                                    Capsule().fill(color(bandFor(part.score))).frame(width: max(6, geo.size.width * CGFloat(part.score) / 100))
                                }
                            }.frame(height: 6)
                            Text(L(part.detail)).font(.caption).foregroundStyle(Tone.ink2).frame(width: 118, alignment: .trailing)
                        }
                    }
                }.padding(.top, 14)
                Text(L("A transparent heuristic from your own HRV, resting heart rate and sleep. Not a medical measure.")).font(.caption).foregroundStyle(Tone.ink3).padding(.top, 12)
            }
            .animation(.snappy, value: readiness.score)
        }
    }
    private func bandFor(_ score: Int) -> String { score >= 67 ? "High" : score >= 34 ? "Balanced" : "Low" }
    private func color(_ band: String) -> Color { band == "High" ? Tone.moss : band == "Low" ? Tone.signal : Tone.ink }
}
