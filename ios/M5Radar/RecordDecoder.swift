// Décodage des notifications DATA : suite d'enregistrements [type u8][len u8][payload].
// Le M5 n'envoie que des enregistrements entiers dans chaque notification.
import Foundation

struct WifiRecord {
    var date: Date?          // nil si le M5 n'avait pas encore l'heure
    var bssid: String
    var rssi: Int
    var channel: Int
    var auth: Int
    var ssid: String
}

struct BLERecord {
    var date: Date?
    var address: String
    var addressType: Int     // 0 public, 1 aléatoire
    var rssi: Int
    var connectable: Bool
    var txPower: Int?
    var name: String
    var manufacturerData: Data   // ID fabricant (2 octets LE) inclus
    var services: [UInt16]

    var companyID: Int? {
        guard manufacturerData.count >= 2 else { return nil }
        return Int(manufacturerData[manufacturerData.startIndex]) |
            Int(manufacturerData[manufacturerData.startIndex + 1]) << 8
    }
}

struct SpectrumChunk {
    var date: Date?
    var offset: Int
    var levels: [UInt8]
}

enum Record {
    case wifi(WifiRecord)
    case ble(BLERecord)
    case spectrum(SpectrumChunk)
}

enum RecordDecoder {
    static func decode(_ data: Data) -> [Record] {
        var out: [Record] = []
        var r = ByteReader(data)
        while r.remaining >= 2 {
            guard let type = r.u8(), let len = r.u8(), let payload = r.take(Int(len)) else { break }
            var p = ByteReader(Data(payload))
            let rec: Record?
            switch type {
            case Proto.recWifi: rec = wifi(&p).map(Record.wifi)
            case Proto.recBle: rec = ble(&p).map(Record.ble)
            case Proto.recSpectrum: rec = spectrum(&p).map(Record.spectrum)
            default: rec = nil  // type inconnu (firmware plus récent) : on saute
            }
            if let rec { out.append(rec) }
        }
        return out
    }

    private static func date(_ ts: UInt32) -> Date? {
        ts == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(ts))
    }

    private static func mac(_ b: [UInt8]) -> String {
        b.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func text(_ b: [UInt8]) -> String {
        String(decoding: b, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
    }

    private static func wifi(_ p: inout ByteReader) -> WifiRecord? {
        guard let ts = p.u32(), let bssid = p.take(6), let rssi = p.i8(), let ch = p.u8(),
              let auth = p.u8(), let sl = p.u8(), let ssid = p.take(Int(sl)) else { return nil }
        return WifiRecord(date: date(ts), bssid: mac(bssid), rssi: Int(rssi), channel: Int(ch),
                          auth: Int(auth), ssid: text(ssid))
    }

    private static func ble(_ p: inout ByteReader) -> BLERecord? {
        guard let ts = p.u32(), let addr = p.take(6), let at = p.u8(), let rssi = p.i8(),
              let flags = p.u8(), let tx = p.i8(), let nl = p.u8(), let name = p.take(Int(nl)),
              let ml = p.u8(), let mfr = p.take(Int(ml)), let sn = p.u8() else { return nil }
        var svcs: [UInt16] = []
        for _ in 0..<sn {
            guard let s = p.u16() else { return nil }
            svcs.append(s)
        }
        return BLERecord(date: date(ts), address: mac(addr), addressType: Int(at), rssi: Int(rssi),
                         connectable: flags & 0x01 != 0, txPower: flags & 0x02 != 0 ? Int(tx) : nil,
                         name: text(name), manufacturerData: Data(mfr), services: svcs)
    }

    private static func spectrum(_ p: inout ByteReader) -> SpectrumChunk? {
        guard let ts = p.u32(), let off = p.u8(), let n = p.u8(), let lv = p.take(Int(n)) else { return nil }
        return SpectrumChunk(date: date(ts), offset: Int(off), levels: lv)
    }
}
