import SwiftUI

struct LiveView: View {
    @Environment(BLELink.self) private var link
    @Environment(Collector.self) private var collector

    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionCard() }
                if let s = link.status {
                    Section("M5") { DeviceCard(status: s) }
                }
                Section("Cette session") {
                    LabeledContent("Nouveaux réseaux Wi-Fi", value: "\(collector.newWifi)")
                    LabeledContent("Nouveaux appareils Bluetooth", value: "\(collector.newBLE)")
                    LabeledContent("Détections reçues", value: "\(collector.receivedRecords)")
                }
                Section {
                    if collector.recent.isEmpty {
                        Text("Rien pour l'instant.").foregroundStyle(.secondary)
                    }
                    ForEach(collector.recent) { DetectionRow(detection: $0) }
                } header: {
                    Text("Appareils vus — \(collector.recent.count)")
                } footer: {
                    Text("Une ligne par appareil. Le nombre à droite est le total de détections depuis l'ouverture de l'app.")
                }
            }
            .navigationTitle("M5Radar")
        }
    }
}

struct ConnectionCard: View {
    @Environment(BLELink.self) private var link

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(color)
            if let hint {
                Text(hint).font(.subheadline).foregroundStyle(.secondary)
            }
            if let problem = link.problem {
                Text(problem).font(.subheadline).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch link.state {
        case .bluetoothOff: "Bluetooth désactivé"
        case .unauthorized: "Accès Bluetooth refusé"
        case .searching: "Recherche du M5…"
        case .connecting: "Connexion…"
        case .pairing: "Appairage"
        case .connected: "Connecté au M5"
        }
    }

    private var hint: String? {
        switch link.state {
        case .unauthorized: "Autorise M5Radar dans Réglages > Confidentialité > Bluetooth."
        case .searching: "Allume le M5 et garde-le à quelques mètres."
        case .pairing: "Saisis le code à 6 chiffres affiché sur l'écran du M5."
        default: nil
        }
    }

    private var icon: String {
        switch link.state {
        case .connected: "checkmark.circle.fill"
        case .bluetoothOff, .unauthorized: "exclamationmark.triangle.fill"
        case .pairing: "lock.circle"
        default: "antenna.radiowaves.left.and.right"
        }
    }

    private var color: Color {
        switch link.state {
        case .connected: .green
        case .bluetoothOff, .unauthorized: .orange
        default: .primary
        }
    }
}

struct DeviceCard: View {
    @Environment(BLELink.self) private var link
    let status: DeviceStatus

    var body: some View {
        LabeledContent("Batterie", value: "\(status.batteryPercent) % · \(String(format: "%.2f", Double(status.batteryMillivolts) / 1000)) V")
        LabeledContent("Captés depuis le démarrage",
                       value: "\(status.wifiSeen) Wi-Fi · \(status.bleSeen) BLE")
        LabeledContent("En attente d'envoi", value: ByteCountFormatter.string(fromByteCount: Int64(status.backlogBytes), countStyle: .file))
        LabeledContent("Allumé depuis", value: Duration.seconds(status.uptime).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        if !status.nrfOK {
            Label("NRF24 non détecté : pas de spectre.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        Toggle("Scan actif", isOn: Binding(get: { status.scanning },
                                           set: { link.send(.scan($0)) }))
        Toggle("Mode éco (scans espacés)", isOn: Binding(get: { status.eco },
                                                         set: { link.send(.eco($0)) }))
        if status.beacon || status.accessPoint {
            Label("Émission en cours (voir Plus > Émission)", systemImage: "dot.radiowaves.up.forward")
                .foregroundStyle(.pink)
        }
    }
}

struct DetectionRow: View {
    let detection: Detection

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: detection.isWifi ? "wifi" : "dot.radiowaves.left.and.right")
                .foregroundStyle(detection.isWifi ? .blue : .purple)
                .frame(width: 24)
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(detection.title).lineLimit(1)
                    if detection.isNew {
                        Text("NOUVEAU").font(.caption2.bold()).foregroundStyle(.green)
                    }
                }
                Text(detection.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(detection.rssi) dBm").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            // Compteur de détections, mis à jour en direct.
            Text("\(detection.count)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText(value: Double(detection.count)))
                .animation(.snappy, value: detection.count)
                .frame(minWidth: 34)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
    }
}
