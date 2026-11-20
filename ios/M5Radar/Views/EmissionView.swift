import SwiftUI

/// Les deux seules fonctions qui émettent. Elles sont coupées à chaque démarrage du M5.
struct EmissionView: View {
    @Environment(BLELink.self) private var link
    @AppStorage("beacon.message") private var message = "Bonjour"
    @AppStorage("ap.ssid") private var ssid = "M5Radar-test"
    @AppStorage("ap.channel") private var channel = 6
    @State private var password = ""     // jamais mémorisé

    var body: some View {
        Form {
            if !link.isReady {
                Text("Connecte d'abord le M5.").foregroundStyle(.secondary)
            }

            Section {
                TextField("Message (20 caractères ASCII max.)", text: $message)
                    .autocorrectionDisabled()
                    .onChange(of: message) { _, v in
                        let clean = String(decoding: Proto.ascii(v, max: Proto.beaconMax), as: UTF8.self)
                        if clean != v { message = clean }
                    }
                if beaconOn {
                    Button("Arrêter la balise", role: .destructive) { link.send(.beacon(on: false, message: "")) }
                } else {
                    Button("Diffuser") { link.send(.beacon(on: true, message: message)) }
                        .disabled(message.isEmpty || !link.isReady)
                }
            } header: {
                Text("Balise Bluetooth")
            } footer: {
                Text("Le message est diffusé comme nom de l'annonce Bluetooth du M5 : n'importe quel téléphone à proximité peut le lire.")
            }

            Section {
                TextField("Nom du réseau (SSID)", text: $ssid)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Mot de passe (vide = ouvert, sinon 8 caractères min.)", text: $password)
                Picker("Canal", selection: $channel) {
                    ForEach(1...13, id: \.self) { Text("\($0)").tag($0) }
                }
                if apOn {
                    LabeledContent("Appareils connectés", value: "\(link.status?.apClients ?? 0)")
                    Button("Couper le point d'accès", role: .destructive) {
                        link.send(.accessPoint(on: false, channel: 0, ssid: "", password: ""))
                    }
                } else {
                    Button("Démarrer le point d'accès") {
                        link.send(.accessPoint(on: true, channel: UInt8(channel), ssid: ssid, password: password))
                    }
                    .disabled(!apValid || !link.isReady)
                }
            } header: {
                Text("Point d'accès de test")
            } footer: {
                Text("Un réseau sans accès Internet, pour tester tes propres appareils. Le M5 refuse un nom déjà présent autour de lui (pas d'usurpation de réseau) : le motif du refus s'affiche sur son écran. Le scan Wi-Fi est en pause tant que le point d'accès est actif.")
            }
        }
        .navigationTitle("Émission")
    }

    private var beaconOn: Bool { link.status?.beacon ?? false }
    private var apOn: Bool { link.status?.accessPoint ?? false }
    private var apValid: Bool {
        let s = Proto.utf8(ssid, max: 32)
        return !s.isEmpty && (password.isEmpty || (8...63).contains(password.utf8.count))
    }
}
