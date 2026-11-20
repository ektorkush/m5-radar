// Données stockées sur l'iPhone (SwiftData). Rien ne quitte le téléphone sauf export explicite.
import Foundation
import SwiftData

@Model
final class WifiAP {
    @Attribute(.unique) var bssid: String
    var ssid: String
    var channel: Int
    var auth: Int
    var firstSeen: Date
    var lastSeen: Date
    var bestRSSI: Int
    var latitude: Double?      // position où le signal était le plus fort
    var longitude: Double?
    var sightings: Int
    var isMine: Bool

    init(bssid: String, ssid: String, channel: Int, auth: Int, date: Date, rssi: Int) {
        self.bssid = bssid
        self.ssid = ssid
        self.channel = channel
        self.auth = auth
        firstSeen = date
        lastSeen = date
        bestRSSI = rssi
        sightings = 0
        isMine = false
    }

    var displayName: String { ssid.isEmpty ? "(réseau masqué)" : ssid }
    var security: String { Vendors.wifiAuth(auth) }
}

@Model
final class BLEDevice {
    @Attribute(.unique) var address: String
    var addressType: Int
    var name: String
    var companyID: Int?
    var manufacturerData: Data
    var services: [Int]
    var txPower: Int?
    var connectable: Bool
    var firstSeen: Date
    var lastSeen: Date
    var bestRSSI: Int
    var latitude: Double?
    var longitude: Double?
    var sightings: Int
    var isMine: Bool

    init(address: String, addressType: Int, date: Date, rssi: Int) {
        self.address = address
        self.addressType = addressType
        name = ""
        manufacturerData = Data()
        services = []
        connectable = false
        firstSeen = date
        lastSeen = date
        bestRSSI = rssi
        sightings = 0
        isMine = false
    }

    var vendor: String? { companyID.flatMap(Vendors.bleCompany) }
    var kind: String? { Vendors.bleKind(companyID: companyID, manufacturerData: manufacturerData, services: services) }
    var addressKind: String { Vendors.bleAddressKind(address: address, type: addressType) }
    var displayName: String {
        if !name.isEmpty { return name }
        if let kind { return kind }
        if let vendor { return "Appareil \(vendor)" }
        return "Appareil inconnu"
    }
}

/// Chaque détection individuelle (pour l'historique et l'export).
@Model
final class Sighting {
    var isWifi: Bool
    var key: String          // BSSID ou adresse BLE
    var date: Date
    var rssi: Int
    var latitude: Double?
    var longitude: Double?

    init(isWifi: Bool, key: String, date: Date, rssi: Int, latitude: Double?, longitude: Double?) {
        self.isWifi = isWifi
        self.key = key
        self.date = date
        self.rssi = rssi
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Un balayage complet des 126 canaux du NRF24 (0..255 = part du temps occupé).
@Model
final class SpectrumSample {
    var date: Date
    var levels: Data

    init(date: Date, levels: Data) {
        self.date = date
        self.levels = levels
    }
}

/// Trace GPS de l'iPhone, utilisée pour positionner les détections reçues en différé.
@Model
final class TrackPoint {
    var date: Date
    var latitude: Double
    var longitude: Double
    var accuracy: Double

    init(date: Date, latitude: Double, longitude: Double, accuracy: Double) {
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }
}
