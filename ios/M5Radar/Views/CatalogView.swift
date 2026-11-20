import MapKit
import SwiftData
import SwiftUI

struct CatalogView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case wifi = "Wi-Fi", ble = "Bluetooth"
        var id: Self { self }
    }

    @State private var kind: Kind = .wifi
    @State private var search = ""
    @State private var onlyOpen = false

    var body: some View {
        NavigationStack {
            Group {
                switch kind {
                case .wifi: WifiList(search: search, onlyOpen: onlyOpen)
                case .ble: BLEList(search: search)
                }
            }
            .searchable(text: $search, prompt: kind == .wifi ? "Nom ou BSSID" : "Nom, fabricant ou adresse")
            .safeAreaInset(edge: .top) {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 4)
                .background(.bar)
            }
            .toolbar {
                if kind == .wifi {
                    Toggle(isOn: $onlyOpen) { Label("Ouverts", systemImage: "lock.open") }
                }
            }
            .navigationTitle("Liste")
        }
    }
}

// MARK: - Wi-Fi

private struct WifiList: View {
    @Query private var aps: [WifiAP]

    init(search: String, onlyOpen: Bool) {
        let all = search.isEmpty
        _aps = Query(filter: #Predicate<WifiAP> { ap in
            (all || ap.ssid.localizedStandardContains(search) || ap.bssid.localizedStandardContains(search))
                && (!onlyOpen || ap.auth == 0)
        }, sort: \WifiAP.lastSeen, order: .reverse)
    }

    var body: some View {
        List(aps) { ap in
            NavigationLink { WifiDetail(ap: ap) } label: {
                HStack {
                    Image(systemName: ap.auth == 0 ? "wifi.exclamationmark" : "wifi")
                        .foregroundStyle(ap.isMine ? .green : (ap.auth == 0 ? .orange : .blue))
                        .frame(width: 24)
                    VStack(alignment: .leading) {
                        Text(ap.displayName).lineLimit(1)
                        Text("\(ap.security) · canal \(ap.channel) · vu \(ap.sightings)×")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ap.lastSeen, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if aps.isEmpty { ContentUnavailableView("Aucun réseau", systemImage: "wifi.slash") } }
    }
}

struct WifiDetail: View {
    @Bindable var ap: WifiAP

    var body: some View {
        List {
            Section {
                LabeledContent("Nom", value: ap.displayName)
                LabeledContent("BSSID", value: ap.bssid)
                if Vendors.isRandomMAC(ap.bssid) {
                    Text("Adresse aléatoire : probablement un partage de connexion ou un appareil mobile.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Sécurité", value: ap.security)
                LabeledContent("Canal", value: "\(ap.channel)")
                LabeledContent("Meilleur signal", value: "\(ap.bestRSSI) dBm")
                Toggle("C'est à moi", isOn: $ap.isMine)
            }
            SeenSection(first: ap.firstSeen, last: ap.lastSeen, count: ap.sightings,
                        latitude: ap.latitude, longitude: ap.longitude, title: ap.displayName)
        }
        .navigationTitle(ap.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Bluetooth

private struct BLEList: View {
    @Query private var devices: [BLEDevice]

    init(search: String) {
        let all = search.isEmpty
        _devices = Query(filter: #Predicate<BLEDevice> { d in
            all || d.name.localizedStandardContains(search) || d.address.localizedStandardContains(search)
        }, sort: \BLEDevice.lastSeen, order: .reverse)
    }

    var body: some View {
        List(devices) { d in
            NavigationLink { BLEDetail(device: d) } label: { BLERow(device: d) }
        }
        .overlay { if devices.isEmpty { ContentUnavailableView("Aucun appareil", systemImage: "dot.radiowaves.left.and.right") } }
    }
}

struct BLERow: View {
    let device: BLEDevice

    var body: some View {
        HStack {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(device.isMine ? .green : .purple)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(device.displayName).lineLimit(1)
                Text([device.vendor, "vu \(device.sightings)×"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(device.lastSeen, format: .relative(presentation: .named))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct BLEDetail: View {
    @Bindable var device: BLEDevice

    var body: some View {
        List {
            Section("Ce qu'il diffuse") {
                LabeledContent("Nom annoncé", value: device.name.isEmpty ? "—" : device.name)
                LabeledContent("Fabricant", value: device.vendor ?? device.companyID.map { String(format: "ID 0x%04X", $0) } ?? "—")
                if let kind = device.kind { LabeledContent("Type probable", value: kind) }
                LabeledContent("Adresse", value: device.address)
                LabeledContent("Type d'adresse", value: device.addressKind)
                if device.addressKind == "aléatoire tournante" {
                    Text("Cette adresse change environ toutes les 15 minutes : le même appareil réapparaît sous une autre adresse.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Connectable", value: device.connectable ? "oui" : "non")
                if let tx = device.txPower { LabeledContent("Puissance annoncée", value: "\(tx) dBm") }
                if !device.services.isEmpty {
                    LabeledContent("Services", value: device.services.map(Vendors.serviceName).joined(separator: ", "))
                }
                if !device.manufacturerData.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Données fabricant")
                        Text(device.manufacturerData.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                LabeledContent("Meilleur signal", value: "\(device.bestRSSI) dBm")
                Toggle("C'est à moi", isOn: $device.isMine)
            }
            SeenSection(first: device.firstSeen, last: device.lastSeen, count: device.sightings,
                        latitude: device.latitude, longitude: device.longitude, title: device.displayName)
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Commun

private struct SeenSection: View {
    let first: Date
    let last: Date
    let count: Int
    let latitude: Double?
    let longitude: Double?
    let title: String

    var body: some View {
        Section("Détections") {
            LabeledContent("Première fois", value: first.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Dernière fois", value: last.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Nombre", value: "\(count)")
            if let latitude, let longitude {
                let c = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 400, longitudinalMeters: 400))) {
                    Marker(title, coordinate: c)
                }
                .frame(height: 180)
                .listRowInsets(EdgeInsets())
                Text("Position où le signal était le plus fort.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Pas de position (localisation indisponible au moment de la détection).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
