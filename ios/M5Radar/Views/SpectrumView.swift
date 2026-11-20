import Charts
import SwiftData
import SwiftUI

/// Occupation de la bande 2,4 GHz mesurée par le NRF24 (canal c = 2400 + c MHz).
struct SpectrumView: View {
    @Environment(Collector.self) private var collector
    @Environment(BLELink.self) private var link
    @State private var since = Date().addingTimeInterval(-3600)

    var body: some View {
        NavigationStack {
            List {
                if link.status?.nrfOK == false {
                    Label("Le M5 ne détecte pas le NRF24 : vérifie le câblage.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Section {
                    if collector.spectrum.count == Proto.nrfChannels {
                        SpectrumChart(levels: collector.spectrum.map(Double.init), color: .teal)
                    } else {
                        Text("En attente d'un balayage complet…").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Dernier balayage")
                } footer: {
                    if let d = collector.spectrumDate {
                        Text("Reçu \(d.formatted(.relative(presentation: .named))). Hauteur = part du temps où le canal était occupé.")
                    }
                }
                SpectrumHistory(since: since)
                Section("Repères") {
                    Label("Wi-Fi 1, 6 et 11 : 2412, 2437 et 2462 MHz", systemImage: "wifi")
                    Label("Annonces Bluetooth : 2402, 2426 et 2480 MHz", systemImage: "dot.radiowaves.left.and.right")
                    Text("Le NRF24 ne fait qu'écouter : il mesure l'énergie, il ne décode rien.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear { since = Date().addingTimeInterval(-3600) }
            .navigationTitle("Spectre 2,4 GHz")
        }
    }
}

private struct SpectrumHistory: View {
    @Query private var samples: [SpectrumSample]

    init(since: Date) {
        _samples = Query(filter: #Predicate<SpectrumSample> { $0.date >= since }, sort: \SpectrumSample.date)
    }

    var body: some View {
        Section {
            if samples.isEmpty {
                Text("Pas encore d'historique.").foregroundStyle(.secondary)
            } else {
                SpectrumChart(levels: average, color: .indigo)
            }
        } header: {
            Text("Moyenne sur la dernière heure")
        } footer: {
            Text("\(samples.count) balayages.")
        }
    }

    private var average: [Double] {
        var sum = [Double](repeating: 0, count: Proto.nrfChannels)
        var n = 0
        for s in samples where s.levels.count == Proto.nrfChannels {
            for (i, v) in s.levels.enumerated() { sum[i] += Double(v) }
            n += 1
        }
        return n == 0 ? sum : sum.map { $0 / Double(n) }
    }
}

struct SpectrumChart: View {
    let levels: [Double]     // 0..255 par canal
    let color: Color

    private static let wifi = [(1, 12), (6, 37), (11, 62)]     // (canal Wi-Fi, canal NRF)
    private static let bleAdv = [2, 26, 80]

    var body: some View {
        Chart {
            ForEach(Self.wifi, id: \.0) { w in
                RectangleMark(xStart: .value("MHz", 2400 + w.1 - 10), xEnd: .value("MHz", 2400 + w.1 + 10))
                    .foregroundStyle(.blue.opacity(0.08))
                    .annotation(position: .top, alignment: .center) {
                        Text("Wi-Fi \(w.0)").font(.caption2).foregroundStyle(.blue)
                    }
            }
            ForEach(Self.bleAdv, id: \.self) { c in
                RuleMark(x: .value("MHz", 2400 + c))
                    .foregroundStyle(.purple.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            ForEach(Array(levels.enumerated()), id: \.offset) { i, v in
                BarMark(x: .value("MHz", 2400 + i), y: .value("Occupation", v / 255 * 100), width: 2)
                    .foregroundStyle(color)
            }
        }
        .chartXScale(domain: 2400...2526)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: [2400, 2425, 2450, 2475, 2500, 2525]) { v in
                AxisGridLine()
                AxisValueLabel { if let mhz = v.as(Int.self) { Text("\(mhz)") } }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { v in
                AxisGridLine()
                AxisValueLabel { if let p = v.as(Int.self) { Text("\(p) %") } }
            }
        }
        .frame(height: 200)
        .padding(.vertical, 8)
    }
}
