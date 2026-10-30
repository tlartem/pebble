import SwiftUI

/// Every number in Pebble, with its method and source.
struct MethodsScreen: View {
    @Environment(\.dismiss) private var dismiss
    private struct Method: Identifiable {
        let id = UUID(); let title: String; let body: String; let source: String; let url: String?
    }
    private let methods: [Method] = [
        Method(title: L("Usual range"), body: L("Your last 7 days are compared with the 60 days before. A range needs 4 recent and 14 earlier days. Resting heart rate and sleep use ±1 standard deviation of your own daily values. Missing days are never counted as zero."), source: "Your own history", url: nil),
        Method(title: L("Heart rate variability"), body: L("Daily HRV is log-transformed and compared with ±0.5 SD of your baseline, the smallest worthwhile change used for rolling HRV monitoring. Apple Health stores SDNN, so values differ from RMSSD-based apps."), source: "Plews et al., 2013 · Sports Medicine", url: "https://pubmed.ncbi.nlm.nih.gov/?term=Plews+Laursen+Stanley+Kilding+Buchheit+2013+training+adaptation+heart+rate+variability+elite+endurance+athletes"),
        Method(title: L("Sleep duration and timing"), body: L("Overlapping asleep stages from one source are merged in noon-to-noon windows. Timing uses the midpoint of the main sleep episode; regularity is its night-to-night variation over 14 nights."), source: "Watson et al., 2015 · Phillips et al., 2017", url: "https://pubmed.ncbi.nlm.nih.gov/?term=Phillips+2017+irregular+sleep+wake+patterns+academic+performance+delayed+circadian"),
        Method(title: L("Readiness"), body: L("A transparent 0–100 recovery heuristic from your own baselines: HRV (40%), resting heart rate (25%), last night’s sleep vs your need (25%) and sleep regularity (10%). Each part is shown; weights rescale to whatever data exists. HRV-led recovery monitoring, not a medical measure."), source: "Plews et al., 2013 · Buchheit, 2014", url: "https://pubmed.ncbi.nlm.nih.gov/?term=Buchheit+2014+monitoring+training+status+with+HR+measures"),
        Method(title: L("Training load"), body: L("Session RPE: whole-session effort (0–10) × minutes. Fitness and fatigue are exponentially weighted daily loads with 42- and 7-day time constants; form is their difference. Sessions without a rating are left out."), source: "Foster et al., 2001 · Banister et al., 1975", url: "https://pubmed.ncbi.nlm.nih.gov/11708692/"),
        Method(title: L("Workload ratio"), body: L("Acute (7-day) over chronic (28-day) exponentially weighted load, seeded to avoid a cold-start bias and shown only after ~8 training days. The 0.8–1.3 “sweet spot” is widely cited but the ratio is debated, so it’s context, not a rule."), source: "Williams et al., 2017 · Impellizzeri et al., 2020", url: "https://pubmed.ncbi.nlm.nih.gov/?term=Williams+2017+better+way+to+determine+the+acute+chronic+workload+ratio+exponentially+weighted"),
        Method(title: L("Social jetlag"), body: L("The gap between your average weekend and weekday sleep midpoints. A larger gap strains the body clock. Shown alongside night-to-night midpoint variability."), source: "Wittmann et al., 2006", url: "https://pubmed.ncbi.nlm.nih.gov/?term=Wittmann+2006+social+jetlag+misalignment+biological+social+time"),
        Method(title: L("Cardio fitness"), body: L("VO₂max ≈ 15.3 × max HR ÷ resting HR, ranked against age- and sex-matched norms. Max HR = 208 − 0.7 × age unless you enter a measured value. A population estimate with roughly ±10–15% individual error."), source: "Uth et al., 2004 · Cooper Institute norms", url: "https://pubmed.ncbi.nlm.nih.gov/?term=Uth+2004+estimation+of+VO2max+from+the+ratio+between+HRmax+and+HRrest"),
        Method(title: L("Heart rate zones"), body: L("Zones start at 50, 60, 70, 80 and 90% of heart-rate reserve (Karvonen). Live sessions record time in each zone and an Edwards zone load (minutes × zone number)."), source: "Karvonen et al., 1957 · Edwards, 1993", url: "https://pubmed.ncbi.nlm.nih.gov/?term=Karvonen+1957+effects+of+training+on+heart+rate+longitudinal+study"),
        Method(title: L("Steps"), body: L("Walking takes about 100 steps per minute at moderate intensity, used for the minutes-to-goal estimate. Mortality benefits level off around 8,000–10,000 daily steps under 60 and 6,000–8,000 from 60."), source: "Tudor-Locke et al., 2018 · Paluch et al., 2022", url: "https://pubmed.ncbi.nlm.nih.gov/?term=Paluch+2022+daily+steps+and+all-cause+mortality+meta-analysis+15+international+cohorts"),
        Method(title: L("Move reminder"), body: L("An hour inside your active hours with fewer steps than your threshold triggers one reminder, at most every two hours. Short walking breaks during long sitting improve post-meal glucose and insulin."), source: "Dunstan et al., 2012 · Diabetes Care", url: "https://pubmed.ncbi.nlm.nih.gov/?term=Dunstan+2012+breaking+up+prolonged+sitting+reduces+postprandial+glucose+and+insulin+responses"),
    ]
    var body: some View {
        List {
            ForEach(methods) { method in
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L(method.title)).font(.headline)
                        Text(L(method.body)).font(.subheadline).foregroundStyle(Tone.ink2)
                        if let link = method.url.flatMap(URL.init(string:)) {
                            Link(destination: link) {
                                Label(L(method.source), systemImage: "arrow.up.right").font(.caption.weight(.medium)).labelStyle(TrailingIcon())
                            }
                        }
                    }.padding(.vertical, 4)
                }
            }
            Section {
                Text(L("Pebble describes change against your own history. It doesn’t diagnose, score readiness or predict injury.")).font(.footnote).foregroundStyle(Tone.ink2)
            }
        }
        .navigationTitle(L("Methods")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 3) { configuration.title; configuration.icon.imageScale(.small) } }
}
