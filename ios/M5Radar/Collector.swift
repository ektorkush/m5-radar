// Range les enregistrements reçus du M5 dans SwiftData : un objet par réseau / appareil
// (fusionné), une ligne Sighting par détection, et les balayages complets du spectre.
import Foundation
import Observation
import SwiftData

struct Detection: Identifiable {
    let id: String          // "w:" + BSSID ou "b:" + adresse BLE : identité stable
    let isWifi: Bool
    let key: String
    var title: String
    var subtitle: String
    var rssi: Int           // dernier signal
    var count: Int          // nombre de détections depuis le lancement de l'app (live)
    var lastSeen: Date
    let isNew: Bool         // jamais enregistré auparavant sur l'iPhone
}

@MainActor
@Observable
final class Collector {
    /// Dernières détections, la plus récente en tête (vue « Direct »).
    private(set) var recent: [Detection] = []
    private(set) var newWifi = 0
    private(set) var newBLE = 0
    private(set) var receivedRecords = 0
    /// Dernier balayage complet du NRF24 (126 canaux, 0..255).
    private(set) var spectrum: [UInt8] = []
    private(set) var spectrumDate: Date?
    /// Appareils BLE entendus dans les dernières secondes : adresse -> (RSSI, date).
    private(set) var liveBLE: [String: (rssi: Int, date: Date)] = [:]

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let location: LocationTracker
    @ObservationIgnored private var wifiCache: [String: WifiAP] = [:]
    @ObservationIgnored private var bleCache: [String: BLEDevice] = [:]
    @ObservationIgnored private var sweep = [UInt8](repeating: 0, count: Proto.nrfChannels)
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(context: ModelContext, location: LocationTracker) {
        self.context = context
        self.location = location
        reloadCache()
    }

    /// À rappeler après une suppression en masse (purge des données).
    func reloadCache() {
        wifiCache = Dictionary(((try? context.fetch(FetchDescriptor<WifiAP>())) ?? []).map { ($0.bssid, $0) },
                               uniquingKeysWith: { a, _ in a })
        bleCache = Dictionary(((try? context.fetch(FetchDescriptor<BLEDevice>())) ?? []).map { ($0.address, $0) },
                              uniquingKeysWith: { a, _ in a })
    }

    func bleDevice(_ address: String) -> BLEDevice? { bleCache[address] }

    func ingest(_ records: [Record]) {
        let now = Date()
        for rec in records {
            receivedRecords += 1
            switch rec {
            case .wifi(let w): ingest(w, now: now)
            case .ble(let b): ingest(b, now: now)
            case .spectrum(let s): ingest(s, now: now)
            }
        }
        liveBLE = liveBLE.filter { now.timeIntervalSince($0.value.date) < 10 }
        scheduleSave()
    }

    /// Met à jour la ligne de l'appareil (compteur, signal, heure) sans la déplacer ;
    /// un appareil jamais vu dans le flux est ajouté en tête. Liste plafonnée.
    private func mark(isWifi: Bool, key: String, title: String, subtitle: String,
                      rssi: Int, date: Date, isNew: Bool) {
        let id = (isWifi ? "w:" : "b:") + key
        if let i = recent.firstIndex(where: { $0.id == id }) {
            recent[i].count += 1
            recent[i].rssi = rssi
            recent[i].lastSeen = date
            recent[i].title = title
            recent[i].subtitle = subtitle
        } else {
            recent.insert(Detection(id: id, isWifi: isWifi, key: key, title: title, subtitle: subtitle,
                                    rssi: rssi, count: 1, lastSeen: date, isNew: isNew), at: 0)
            if recent.count > 60 { recent.removeLast(recent.count - 60) }
        }
    }

    // MARK: - Par type

    private func ingest(_ w: WifiRecord, now: Date) {
        let date = w.date ?? now
        let pos = w.date == nil ? nil : location.position(at: date)
        let isNew = wifiCache[w.bssid] == nil
        let ap = wifiCache[w.bssid] ?? {
            let ap = WifiAP(bssid: w.bssid, ssid: w.ssid, channel: w.channel, auth: w.auth, date: date, rssi: w.rssi)
            context.insert(ap)
            wifiCache[w.bssid] = ap
            newWifi += 1
            return ap
        }()
        if !w.ssid.isEmpty { ap.ssid = w.ssid }
        ap.channel = w.channel
        ap.auth = w.auth
        ap.sightings += 1
        if date < ap.firstSeen { ap.firstSeen = date }
        if date > ap.lastSeen { ap.lastSeen = date }
        if let pos, ap.latitude == nil || w.rssi >= ap.bestRSSI {
            ap.latitude = pos.latitude
            ap.longitude = pos.longitude
        }
        ap.bestRSSI = max(ap.bestRSSI, w.rssi)
        context.insert(Sighting(isWifi: true, key: w.bssid, date: date, rssi: w.rssi,
                                latitude: pos?.latitude, longitude: pos?.longitude))
        mark(isWifi: true, key: w.bssid, title: ap.displayName,
             subtitle: "Canal \(w.channel) · \(ap.security)", rssi: w.rssi, date: date, isNew: isNew)
    }

    private func ingest(_ b: BLERecord, now: Date) {
        let date = b.date ?? now
        let pos = b.date == nil ? nil : location.position(at: date)
        let isNew = bleCache[b.address] == nil
        let dev = bleCache[b.address] ?? {
            let d = BLEDevice(address: b.address, addressType: b.addressType, date: date, rssi: b.rssi)
            context.insert(d)
            bleCache[b.address] = d
            newBLE += 1
            return d
        }()
        if !b.name.isEmpty { dev.name = b.name }
        if let id = b.companyID {
            dev.companyID = id
            dev.manufacturerData = b.manufacturerData
        }
        if !b.services.isEmpty { dev.services = Array(Set(dev.services + b.services.map(Int.init))).sorted() }
        if let tx = b.txPower { dev.txPower = tx }
        dev.connectable = b.connectable
        dev.sightings += 1
        if date < dev.firstSeen { dev.firstSeen = date }
        if date > dev.lastSeen { dev.lastSeen = date }
        if let pos, dev.latitude == nil || b.rssi >= dev.bestRSSI {
            dev.latitude = pos.latitude
            dev.longitude = pos.longitude
        }
        dev.bestRSSI = max(dev.bestRSSI, b.rssi)
        context.insert(Sighting(isWifi: false, key: b.address, date: date, rssi: b.rssi,
                                latitude: pos?.latitude, longitude: pos?.longitude))
        // Seules les détections récentes comptent pour « Mes appareils » (pas le tampon rejoué).
        if now.timeIntervalSince(date) < 10 { liveBLE[b.address] = (b.rssi, date) }
        let detail = [dev.vendor, dev.kind].compactMap { $0 }.joined(separator: " · ")
        mark(isWifi: false, key: b.address, title: dev.displayName,
             subtitle: detail.isEmpty ? b.address : detail, rssi: b.rssi, date: date, isNew: isNew)
    }

    private func ingest(_ s: SpectrumChunk, now: Date) {
        guard s.offset >= 0, s.offset + s.levels.count <= Proto.nrfChannels else { return }
        sweep.replaceSubrange(s.offset..<s.offset + s.levels.count, with: s.levels)
        // Le M5 envoie un balayage en morceaux croissants ; le dernier ferme le balayage.
        guard s.offset + s.levels.count == Proto.nrfChannels else { return }
        let date = s.date ?? now
        context.insert(SpectrumSample(date: date, levels: Data(sweep)))
        if spectrumDate.map({ date >= $0 }) ?? true {
            spectrum = sweep
            spectrumDate = date
        }
    }

    // MARK: - Sauvegarde groupée

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            try? self.context.save()
            self.saveTask = nil
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        try? context.save()
    }
}
