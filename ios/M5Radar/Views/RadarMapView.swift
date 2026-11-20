import MapKit
import SwiftData
import SwiftUI

struct RadarMapView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "Tout", wifi = "Wi-Fi", ble = "Bluetooth"
        var id: Self { self }
    }

    enum Period: String, CaseIterable, Identifiable {
        case hour = "1 h", day = "24 h", week = "7 j", all = "Tout"
        var id: Self { self }
        var since: Date {
            switch self {
            case .hour: Date().addingTimeInterval(-3600)
            case .day: Date().addingTimeInterval(-86400)
            case .week: Date().addingTimeInterval(-7 * 86400)
            case .all: .distantPast
            }
        }
    }

    /// Au-delà, la carte devient lente : on garde les plus récents.
    private let maxMarkers = 1500

    @Query(filter: #Predicate<WifiAP> { $0.latitude != nil }, sort: \WifiAP.lastSeen, order: .reverse)
    private var aps: [WifiAP]
    @Query(filter: #Predicate<BLEDevice> { $0.latitude != nil }, sort: \BLEDevice.lastSeen, order: .reverse)
    private var devices: [BLEDevice]

    @State private var kind: Kind = .all
    @State private var period: Period = .day
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                UserAnnotation()
                if kind != .ble {
                    ForEach(visibleAPs) { ap in
                        Marker(ap.displayName, systemImage: Self.symbol(ap), coordinate: coord(ap.latitude, ap.longitude))
                            .tint(Self.color(ap))
                    }
                }
                if kind != .wifi {
                    ForEach(visibleDevices) { d in
                        Marker(d.displayName, systemImage: "dot.radiowaves.left.and.right",
                               coordinate: coord(d.latitude, d.longitude))
                            .tint(Self.color(d))
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 6) {
                    Picker("Type", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Période", selection: $period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if truncated {
                        Text("Seuls les \(maxMarkers) plus récents sont affichés.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .pickerStyle(.segmented)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }
            .navigationTitle("Carte")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var filteredAPs: [WifiAP] {
        let since = period.since
        return aps.filter { $0.lastSeen >= since }
    }

    private var filteredDevices: [BLEDevice] {
        let since = period.since
        return devices.filter { $0.lastSeen >= since }
    }

    private var visibleAPs: [WifiAP] {
        Array(filteredAPs.prefix(kind == .wifi ? maxMarkers : maxMarkers / 2))
    }

    private var visibleDevices: [BLEDevice] {
        Array(filteredDevices.prefix(kind == .ble ? maxMarkers : maxMarkers / 2))
    }

    private var truncated: Bool {
        (kind != .ble && filteredAPs.count > visibleAPs.count) ||
            (kind != .wifi && filteredDevices.count > visibleDevices.count)
    }

    private static func symbol(_ ap: WifiAP) -> String {
        ap.auth == 0 ? "wifi.exclamationmark" : "wifi"
    }

    private static func color(_ ap: WifiAP) -> Color {
        if ap.isMine { return .green }
        return ap.auth == 0 ? .orange : .blue
    }

    private static func color(_ d: BLEDevice) -> Color {
        d.isMine ? .green : .purple
    }

    private func coord(_ lat: Double?, _ lon: Double?) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat ?? 0, longitude: lon ?? 0)
    }
}
