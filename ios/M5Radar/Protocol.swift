// Protocole binaire M5 <-> iPhone. Miroir de firmware/include/protocol.h :
// toute modification doit être faite des deux côtés.
import CoreBluetooth
import Foundation

enum Proto {
    static let service = CBUUID(string: "6e5a0001-7a3b-4c1d-9e2f-5b6a7c8d9e0f")
    static let data = CBUUID(string: "6e5a0002-7a3b-4c1d-9e2f-5b6a7c8d9e0f")
    static let cmd = CBUUID(string: "6e5a0003-7a3b-4c1d-9e2f-5b6a7c8d9e0f")
    static let status = CBUUID(string: "6e5a0004-7a3b-4c1d-9e2f-5b6a7c8d9e0f")

    static let recWifi: UInt8 = 0x01
    static let recBle: UInt8 = 0x02
    static let recSpectrum: UInt8 = 0x03

    static let statusVersion: UInt8 = 1
    static let statusLen = 22
    static let beaconMax = 20
    static let nrfChannels = 126

    enum Command {
        case setTime(Date)
        case scan(Bool)
        case beacon(on: Bool, message: String)
        case accessPoint(on: Bool, channel: UInt8, ssid: String, password: String)
        case purge
        case eco(Bool)

        var bytes: Data {
            var w = ByteWriter()
            switch self {
            case .setTime(let date):
                w.u8(0x01)
                w.u32(UInt32(max(0, date.timeIntervalSince1970)))
            case .scan(let on):
                w.u8(0x02); w.u8(on ? 1 : 0)
            case .beacon(let on, let message):
                let msg = Proto.ascii(message, max: Proto.beaconMax)
                w.u8(0x03); w.u8(on ? 1 : 0); w.u8(UInt8(msg.count)); w.bytes(msg)
            case .accessPoint(let on, let channel, let ssid, let password):
                let s = Proto.utf8(ssid, max: 32)
                let p = Proto.utf8(password, max: 63)
                w.u8(0x04); w.u8(on ? 1 : 0); w.u8(channel)
                w.u8(UInt8(s.count)); w.bytes(s)
                w.u8(UInt8(p.count)); w.bytes(p)
            case .purge:
                w.u8(0x05)
            case .eco(let on):
                w.u8(0x06); w.u8(on ? 1 : 0)
            }
            return w.data
        }
    }

    /// Texte affichable par la balise : ASCII imprimable uniquement (le M5 filtre de même).
    static func ascii(_ s: String, max: Int) -> Data {
        Data(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }.prefix(max).map { UInt8($0.value) })
    }

    /// UTF-8 tronqué sans couper un caractère au milieu.
    static func utf8(_ s: String, max: Int) -> Data {
        var out = Data()
        for ch in s {
            let b = Data(String(ch).utf8)
            if out.count + b.count > max { break }
            out.append(b)
        }
        return out
    }
}

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { u8(UInt8(v & 0xFF)); u8(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
    mutating func bytes(_ d: Data) { data.append(d) }
}

/// Lecteur little-endian ; renvoie nil dès qu'on dépasse la fin.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var pos = 0
    init(_ data: Data) { bytes = [UInt8](data) }
    var remaining: Int { bytes.count - pos }

    mutating func u8() -> UInt8? {
        guard pos < bytes.count else { return nil }
        defer { pos += 1 }
        return bytes[pos]
    }
    mutating func i8() -> Int8? { u8().map { Int8(bitPattern: $0) } }
    mutating func u16() -> UInt16? {
        guard let a = u8(), let b = u8() else { return nil }
        return UInt16(a) | UInt16(b) << 8
    }
    mutating func u32() -> UInt32? {
        guard let a = u16(), let b = u16() else { return nil }
        return UInt32(a) | UInt32(b) << 16
    }
    mutating func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, pos + n <= bytes.count else { return nil }
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }
}

struct DeviceStatus: Equatable {
    var batteryPercent: Int
    var batteryMillivolts: Int
    var scanning: Bool
    var eco: Bool
    var nrfOK: Bool
    var beacon: Bool
    var accessPoint: Bool
    var timeValid: Bool
    var apClients: Int
    var wifiSeen: Int
    var bleSeen: Int
    var backlogBytes: Int
    var uptime: TimeInterval

    init?(_ data: Data) {
        var r = ByteReader(data)
        guard data.count >= Proto.statusLen, r.u8() == Proto.statusVersion,
              let pct = r.u8(), let mv = r.u16(), let flags = r.u8(), let clients = r.u8(),
              let wifi = r.u32(), let ble = r.u32(), let backlog = r.u32(), let up = r.u32()
        else { return nil }
        batteryPercent = Int(pct)
        batteryMillivolts = Int(mv)
        scanning = flags & 0x01 != 0
        eco = flags & 0x02 != 0
        nrfOK = flags & 0x04 != 0
        beacon = flags & 0x08 != 0
        accessPoint = flags & 0x10 != 0
        timeValid = flags & 0x20 != 0
        apClients = Int(clients)
        wifiSeen = Int(wifi)
        bleSeen = Int(ble)
        backlogBytes = Int(backlog)
        uptime = TimeInterval(up)
    }
}
