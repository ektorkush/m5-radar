import SwiftData
import SwiftUI

/// Repérer ses propres appareils : on les approche du M5, le plus fort signal est le bon.
struct MyDevicesView: View {
    @Environment(Collector.self) private var collector
    @Environment(BLELink.self) private var link
    @Query(filter: #Predicate<BLEDevice> { $0.isMine }, sort: \BLEDevice.lastSeen, order: .reverse)
    private var myDevices: [BLEDevice]
    @Query(filter: #Predicate<WifiAP> { $0.isMine }, sort: \WifiAP.lastSeen, order: .reverse)
    private var myNetworks: [WifiAP]

    var body: some View {
        List {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let near = nearby(at: ctx.date)
                    if !link.isReady {
                        Text("Connecte d'abord le M5.").foregroundStyle(.secondary)
                    } else if near.isEmpty {
                        Text("Aucun appareil entendu ces 10 dernières secondes.").foregroundStyle(.secondary)
                    } else {
                        ForEach(near, id: \.address) { item in
                            NearbyRow(address: item.address, rssi: item.rssi,
                                      device: collector.bleDevice(item.address))
                        }
                    }
                }
            } header: {
                Text("Approche ton appareil à moins de 10 cm du M5")
            } footer: {
                Text("Le premier de la liste a le signal le plus fort. Un appareil Apple ou Android change d'adresse toutes les ~15 min : il faudra peut-être le marquer à nouveau plus tard.")
            }

            Section("Mes appareils Bluetooth") {
                if myDevices.isEmpty {
                    Text("Aucun pour l'instant.").foregroundStyle(.secondary)
                }
                ForEach(myDevices) { d in
                    NavigationLink { BLEDetail(device: d) } label: { BLERow(device: d) }
                }
            }

            Section {
                if myNetworks.isEmpty {
                    Text("Marque-les depuis l'onglet Liste.").foregroundStyle(.secondary)
                }
                ForEach(myNetworks) { ap in
                    NavigationLink { WifiDetail(ap: ap) } label: {
                        LabeledContent(ap.displayName, value: "vu \(ap.sightings)×")
                    }
                }
            } header: {
                Text("Mes réseaux Wi-Fi")
            }
        }
        .navigationTitle("Mes appareils")
    }

    private func nearby(at now: Date) -> [(address: String, rssi: Int)] {
        collector.liveBLE
            .filter { now.timeIntervalSince($0.value.date) < 10 }
            .map { (address: $0.key, rssi: $0.value.rssi) }
            .sorted { $0.rssi > $1.rssi }
            .prefix(6)
            .map { $0 }
    }
}

private struct NearbyRow: View {
    let address: String
    let rssi: Int
    let device: BLEDevice?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(device?.displayName ?? address).lineLimit(1)
                Text([device?.vendor, address].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(rssi) dBm").font(.caption.monospacedDigit())
            if let device {
                Button(device.isMine ? "À moi ✓" : "C'est à moi") { device.isMine.toggle() }
                    .buttonStyle(.bordered)
                    .tint(device.isMine ? .green : .accentColor)
            }
        }
    }
}
