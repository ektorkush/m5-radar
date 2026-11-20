// Trace GPS de l'iPhone. Les détections sont horodatées par le M5 (heure fournie par l'iPhone) ;
// on retrouve ensuite la position de l'iPhone à cet instant dans la trace.
import CoreLocation
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var last: CLLocation?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var track: [TrackPoint] = []   // triée par date
    /// Écart maximal toléré entre une détection et le point GPS le plus proche.
    @ObservationIgnored private let maxGap: TimeInterval = 120

    func start(context: ModelContext) {
        self.context = context
        reloadTrack()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // Pas de filtre de distance : immobile, on continue de recevoir des positions,
        // sinon les détections faites à l'arrêt resteraient sans coordonnées.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            begin()
        }
    }

    func requestAlways() { manager.requestAlwaysAuthorization() }

    /// Recharge la trace des 7 derniers jours (au démarrage et après effacement des données).
    func reloadTrack() {
        guard let context else { return }
        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        let fd = FetchDescriptor<TrackPoint>(predicate: #Predicate { $0.date > since },
                                             sortBy: [SortDescriptor(\.date)])
        track = (try? context.fetch(fd)) ?? []
    }

    private func begin() {
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return }
        if authorization == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    /// Position de l'iPhone au moment `date`, ou nil si la trace ne couvre pas cet instant.
    func position(at date: Date) -> CLLocationCoordinate2D? {
        // Cas courant : détection en direct, la dernière position suffit.
        if let last, abs(last.timestamp.timeIntervalSince(date)) <= 15 { return last.coordinate }
        guard !track.isEmpty else { return nil }
        // Recherche dichotomique du premier point postérieur à `date`.
        var lo = 0, hi = track.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if track[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        let after = lo < track.count ? track[lo] : nil
        let before = lo > 0 ? track[lo - 1] : nil
        switch (before, after) {
        case let (b?, a?):
            let span = a.date.timeIntervalSince(b.date)
            guard span <= 2 * maxGap else {
                let near = date.timeIntervalSince(b.date) < a.date.timeIntervalSince(date) ? b : a
                return abs(near.date.timeIntervalSince(date)) <= maxGap ? coord(near) : nil
            }
            let t = span > 0 ? date.timeIntervalSince(b.date) / span : 0
            return CLLocationCoordinate2D(latitude: b.latitude + (a.latitude - b.latitude) * t,
                                          longitude: b.longitude + (a.longitude - b.longitude) * t)
        case let (b?, nil):
            return abs(date.timeIntervalSince(b.date)) <= maxGap ? coord(b) : nil
        case let (nil, a?):
            return abs(a.date.timeIntervalSince(date)) <= maxGap ? coord(a) : nil
        default:
            return nil
        }
    }

    private func coord(_ p: TrackPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            authorization = manager.authorizationStatus
            begin()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for loc in locations where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= 100 {
                last = loc
                // Trace stockée : un point tous les 10 m, ou toutes les 60 s à l'arrêt.
                if let tail = track.last {
                    let moved = CLLocation(latitude: tail.latitude, longitude: tail.longitude).distance(from: loc)
                    if moved < 10 && loc.timestamp.timeIntervalSince(tail.date) < 60 { continue }
                }
                let p = TrackPoint(date: loc.timestamp, latitude: loc.coordinate.latitude,
                                   longitude: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy)
                context?.insert(p)
                if let tail = track.last, tail.date > p.date {
                    track.append(p)
                    track.sort { $0.date < $1.date }
                } else {
                    track.append(p)
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
