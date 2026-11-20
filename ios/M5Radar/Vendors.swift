// Identification « à vue » : identifiants Bluetooth SIG les plus courants, sous-types Apple
// Continuity et services 16 bits connus. Volontairement court : seules des valeurs sûres.
import Foundation

enum Vendors {
    static func bleCompany(_ id: Int) -> String? {
        switch id {
        case 0x0006: return "Microsoft"
        case 0x000F: return "Broadcom"
        case 0x004C: return "Apple"
        case 0x0059: return "Nordic Semiconductor"
        case 0x0075: return "Samsung"
        case 0x0087: return "Garmin"
        case 0x009E: return "Bose"
        case 0x00E0: return "Google"
        case 0x012D: return "Sony"
        case 0x0171: return "Amazon"
        case 0x027D: return "Huawei"
        case 0x02E5: return "Espressif"
        case 0x038F: return "Xiaomi"
        default: return nil
        }
    }

    /// Type d'appareil déduit des données annoncées, quand c'est reconnaissable.
    static func bleKind(companyID: Int?, manufacturerData: Data, services: [Int]) -> String? {
        if companyID == 0x004C, manufacturerData.count >= 3 {
            switch manufacturerData[manufacturerData.startIndex + 2] {
            case 0x02: return "iBeacon"
            case 0x05: return "Apple (AirDrop)"
            case 0x07: return "AirPods / Beats"
            case 0x09: return "Apple (AirPlay)"
            case 0x0C: return "Apple (Handoff)"
            case 0x0F: return "Apple (action à proximité)"
            case 0x10: return "iPhone / iPad / Mac"
            case 0x12: return "Réseau Localiser (AirTag ou appareil perdu)"
            default: return nil
            }
        }
        for s in services {
            switch s {
            case 0xFD6F: return "Notification d'exposition"
            case 0xFEAA: return "Balise Eddystone"
            case 0xFEED, 0xFEEC: return "Tile"
            case 0x180D: return "Capteur cardiaque"
            case 0x1812: return "Clavier / souris"
            default: continue
            }
        }
        return nil
    }

    /// Les adresses aléatoires « résolvables » changent toutes les ~15 min :
    /// un même appareil apparaît alors sous plusieurs adresses.
    static func bleAddressKind(address: String, type: Int) -> String {
        guard type == 1, let first = UInt8(address.prefix(2), radix: 16) else { return "publique" }
        switch first >> 6 {
        case 0b11: return "aléatoire statique"
        case 0b01: return "aléatoire tournante"
        default: return "aléatoire non résolvable"
        }
    }

    static func wifiAuth(_ auth: Int) -> String {
        switch auth {
        case 0: return "Ouvert"
        case 1: return "WEP"
        case 2: return "WPA"
        case 3: return "WPA2"
        case 4: return "WPA/WPA2"
        case 5: return "WPA2 Entreprise"
        case 6: return "WPA3"
        case 7: return "WPA2/WPA3"
        case 8: return "WAPI"
        default: return "Autre (\(auth))"
        }
    }

    /// Bit « administré localement » : adresse Wi-Fi aléatoire (souvent un partage de connexion).
    static func isRandomMAC(_ mac: String) -> Bool {
        guard let first = UInt8(mac.prefix(2), radix: 16) else { return false }
        return first & 0x02 != 0
    }

    static func serviceName(_ uuid: Int) -> String {
        switch uuid {
        case 0x180A: return "Infos appareil"
        case 0x180D: return "Fréquence cardiaque"
        case 0x180F: return "Batterie"
        case 0x1812: return "HID"
        case 0xFD6F: return "Exposition"
        case 0xFEAA: return "Eddystone"
        case 0xFEED, 0xFEEC: return "Tile"
        default: return String(format: "0x%04X", uuid)
        }
    }
}
