import SwiftData
import SwiftUI

/// Export CSV (tableurs) et GeoJSON (cartes : QGIS, geojson.io, uMap…).
/// Les fichiers sont créés dans le dossier temporaire puis partagés ; rien n'est envoyé ailleurs.
struct ExportView: View {
    @Environment(\.modelContext) private var context
    @State private var period: Period = .all
    @State private var files: [URL] = []
    @State private var working = false
    @State private var error: String?

    enum Period: String, CaseIterable, Identifiable {
        case day = "24 h", week = "7 jours", all = "Tout"
        var id: Self { self }
        var since: Date {
            switch self {
            case .day: Date().addingTimeInterval(-86_400)
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .all: .distantPast
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Période", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: period) { files = [] }
                Button {
                    build()
                } label: {
                    if working { ProgressView() } else { Text("Préparer les fichiers") }
                }
                .disabled(working)
            } footer: {
                Text("Période = appareils vus au moins une fois dans l'intervalle (date de dernière détection).")
            }

            if !files.isEmpty {
                Section("Fichiers") {
                    ForEach(files, id: \.self) { url in
                        LabeledContent(url.lastPathComponent, value: size(url))
                    }
                    ShareLink(items: files) {
                        Label("Partager / Enregistrer dans Fichiers", systemImage: "square.and.arrow.up")
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("Export")
    }

    private func build() {
        working = true
        error = nil
        defer { working = false }
        do {
            files = try Exporter(context: context, since: period.since).writeAll()
        } catch {
            files = []
            self.error = "Échec de l'export : \(error.localizedDescription)"
        }
    }

    private func size(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct Exporter {
    let context: ModelContext
    let since: Date

    func writeAll() throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("M5Radar-export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day())

        let s = since
        let aps = try context.fetch(FetchDescriptor<WifiAP>(predicate: #Predicate { $0.lastSeen >= s },
                                                             sortBy: [SortDescriptor(\.firstSeen)]))
        let devices = try context.fetch(FetchDescriptor<BLEDevice>(predicate: #Predicate { $0.lastSeen >= s },
                                                                   sortBy: [SortDescriptor(\.firstSeen)]))
        let sightings = try context.fetch(FetchDescriptor<Sighting>(predicate: #Predicate { $0.date >= s },
                                                                    sortBy: [SortDescriptor(\.date)]))
        let track = try context.fetch(FetchDescriptor<TrackPoint>(predicate: #Predicate { $0.date >= s },
                                                                  sortBy: [SortDescriptor(\.date)]))

        var urls: [URL] = []
        func write(_ name: String, _ text: String) throws {
            let url = dir.appendingPathComponent("m5radar-\(name)-\(stamp)")
            try Data(text.utf8).write(to: url, options: .atomic)
            urls.append(url)
        }
        try write("wifi.csv", wifiCSV(aps))
        try write("bluetooth.csv", bleCSV(devices))
        try write("detections.csv", sightingsCSV(sightings))
        try write("carte.geojson", geoJSON(aps: aps, devices: devices, track: track))
        return urls
    }

    // MARK: CSV

    private func wifiCSV(_ aps: [WifiAP]) -> String {
        var out = "bssid,ssid,canal,securite,premiere_detection,derniere_detection,meilleur_rssi,latitude,longitude,detections,a_moi\n"
        for ap in aps {
            out += row([ap.bssid, ap.ssid, "\(ap.channel)", ap.security, iso(ap.firstSeen), iso(ap.lastSeen),
                        "\(ap.bestRSSI)", coord(ap.latitude), coord(ap.longitude), "\(ap.sightings)", ap.isMine ? "1" : "0"])
        }
        return out
    }

    private func bleCSV(_ devices: [BLEDevice]) -> String {
        var out = "adresse,type_adresse,nom,fabricant,type_appareil,company_id,services,tx_power,connectable,premiere_detection,derniere_detection,meilleur_rssi,latitude,longitude,detections,a_moi\n"
        for d in devices {
            out += row([d.address, d.addressKind, d.name, d.vendor ?? "", d.kind ?? "",
                        d.companyID.map { String(format: "0x%04X", $0) } ?? "",
                        d.services.map { String(format: "0x%04X", $0) }.joined(separator: " "),
                        d.txPower.map(String.init) ?? "", d.connectable ? "1" : "0",
                        iso(d.firstSeen), iso(d.lastSeen), "\(d.bestRSSI)",
                        coord(d.latitude), coord(d.longitude), "\(d.sightings)", d.isMine ? "1" : "0"])
        }
        return out
    }

    private func sightingsCSV(_ sightings: [Sighting]) -> String {
        var out = "date,type,identifiant,rssi,latitude,longitude\n"
        for s in sightings {
            out += row([iso(s.date), s.isWifi ? "wifi" : "ble", s.key, "\(s.rssi)", coord(s.latitude), coord(s.longitude)])
        }
        return out
    }

    private func row(_ fields: [String]) -> String {
        fields.map { f in
            // Neutralise les formules (=, +, -, @) qu'un SSID malveillant pourrait injecter dans un tableur.
            var v = f
            if let first = v.first, "=+-@".contains(first), Double(v) == nil { v = "'" + v }
            if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return v
        }.joined(separator: ",") + "\n"
    }

    private func iso(_ d: Date) -> String { d.ISO8601Format() }
    private func coord(_ v: Double?) -> String { v.map { String(format: "%.6f", $0) } ?? "" }

    // MARK: GeoJSON

    private func geoJSON(aps: [WifiAP], devices: [BLEDevice], track: [TrackPoint]) throws -> String {
        var features: [[String: Any]] = []
        for ap in aps {
            guard let lat = ap.latitude, let lon = ap.longitude else { continue }
            features.append(point(lat, lon, [
                "type": "wifi", "nom": ap.displayName, "bssid": ap.bssid, "canal": ap.channel,
                "securite": ap.security, "meilleur_rssi": ap.bestRSSI, "detections": ap.sightings,
                "premiere_detection": iso(ap.firstSeen), "derniere_detection": iso(ap.lastSeen), "a_moi": ap.isMine,
            ]))
        }
        for d in devices {
            guard let lat = d.latitude, let lon = d.longitude else { continue }
            features.append(point(lat, lon, [
                "type": "bluetooth", "nom": d.displayName, "adresse": d.address, "fabricant": d.vendor ?? "",
                "type_appareil": d.kind ?? "", "meilleur_rssi": d.bestRSSI, "detections": d.sightings,
                "premiere_detection": iso(d.firstSeen), "derniere_detection": iso(d.lastSeen), "a_moi": d.isMine,
            ]))
        }
        if track.count >= 2 {
            features.append([
                "type": "Feature",
                "geometry": ["type": "LineString", "coordinates": track.map { [$0.longitude, $0.latitude] }],
                "properties": ["type": "trajet", "debut": iso(track[0].date), "fin": iso(track[track.count - 1].date)],
            ])
        }
        let json: [String: Any] = ["type": "FeatureCollection", "features": features]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func point(_ lat: Double, _ lon: Double, _ props: [String: Any]) -> [String: Any] {
        ["type": "Feature", "geometry": ["type": "Point", "coordinates": [lon, lat]], "properties": props]
    }
}
