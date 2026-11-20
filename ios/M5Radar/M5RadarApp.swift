import SwiftData
import SwiftUI

@main
struct M5RadarApp: App {
    private let container: ModelContainer
    @State private var location: LocationTracker
    @State private var link: BLELink
    @State private var collector: Collector
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: WifiAP.self, BLEDevice.self, Sighting.self,
                                           SpectrumSample.self, TrackPoint.self)
        } catch {
            fatalError("Base de données illisible : \(error)")
        }
        let location = LocationTracker()
        let link = BLELink()
        let collector = Collector(context: container.mainContext, location: location)
        link.onRecords = { [weak collector] in collector?.ingest($0) }

        // Démarrage dès le lancement (et non à l'affichage) : quand iOS relance l'app en
        // arrière-plan pour restaurer la liaison Bluetooth, aucune vue n'est affichée.
        location.start(context: container.mainContext)
        link.start()

        self.container = container
        _location = State(initialValue: location)
        _link = State(initialValue: link)
        _collector = State(initialValue: collector)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(location)
                .environment(link)
                .environment(collector)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { collector.saveNow() }
            // Remet l'heure du M5 à jour à chaque retour dans l'app.
            if phase == .active { link.send(.setTime(Date())) }
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Direct", systemImage: "dot.radiowaves.left.and.right") }
            RadarMapView()
                .tabItem { Label("Carte", systemImage: "map") }
            CatalogView()
                .tabItem { Label("Liste", systemImage: "list.bullet") }
            SpectrumView()
                .tabItem { Label("Spectre", systemImage: "waveform") }
            MoreView()
                .tabItem { Label("Plus", systemImage: "ellipsis.circle") }
        }
    }
}
