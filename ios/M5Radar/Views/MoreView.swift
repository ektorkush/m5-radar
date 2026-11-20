import CoreLocation
import SwiftData
import SwiftUI

struct MoreView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink { MyDevicesView() } label: {
                    Label("Mes appareils", systemImage: "person.crop.circle.badge.checkmark")
                }
                NavigationLink { EmissionView() } label: {
                    Label("Émission (balise, point d'accès)", systemImage: "dot.radiowaves.up.forward")
                }
                NavigationLink { ExportView() } label: {
                    Label("Exporter", systemImage: "square.and.arrow.up")
                }
                NavigationLink { SettingsView() } label: {
                    Label("Réglages et données", systemImage: "gearshape")
                }
            }
            .navigationTitle("Plus")
        }
    }
}

struct SettingsView: View {
    @Environment(BLELink.self) private var link
    @Environment(LocationTracker.self) private var location
    @Environment(Collector.self) private var collector
    @Environment(\.modelContext) private var context
    @State private var confirmWipe = false
    @State private var confirmPurge = false

    var body: some View {
        List {
            Section {
                LabeledContent("Autorisation", value: locationText)
                if location.authorization == .authorizedWhenInUse {
                    Button("Autoriser en arrière-plan") { location.requestAlways() }
                }
            } header: {
                Text("Localisation")
            } footer: {
                Text("« Toujours » permet de positionner les détections quand l'iPhone est verrouillé dans ta poche.")
            }

            Section("M5") {
                Button("Vider le tampon du M5", role: .destructive) { confirmPurge = true }
                    .disabled(!link.isReady)
                Button("Oublier ce M5") { link.forget() }
            }

            Section {
                Button("Effacer toutes les données de l'iPhone", role: .destructive) { confirmWipe = true }
            } footer: {
                Text("Tout reste sur l'iPhone : rien n'est envoyé ailleurs, sauf si tu exportes.")
            }
        }
        .navigationTitle("Réglages")
        .confirmationDialog("Effacer les réseaux, appareils, détections, spectres et la trace GPS ?",
                            isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Tout effacer", role: .destructive, action: wipe)
        }
        .confirmationDialog("Supprimer les détections que le M5 n'a pas encore envoyées ?",
                            isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("Vider le tampon", role: .destructive) { link.send(.purge) }
        }
    }

    private var locationText: String {
        switch location.authorization {
        case .authorizedAlways: "Toujours"
        case .authorizedWhenInUse: "Pendant l'utilisation"
        case .denied, .restricted: "Refusée"
        default: "Non demandée"
        }
    }

    private func wipe() {
        collector.saveNow()
        try? context.delete(model: Sighting.self)
        try? context.delete(model: WifiAP.self)
        try? context.delete(model: BLEDevice.self)
        try? context.delete(model: SpectrumSample.self)
        try? context.delete(model: TrackPoint.self)
        try? context.save()
        collector.reloadCache()
        location.reloadTrack()
    }
}
