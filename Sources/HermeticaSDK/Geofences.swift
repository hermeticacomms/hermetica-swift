import CoreLocation
import Foundation

public struct Geofence: Equatable {
    public let id: String
    public let name: String
    public let latitude: Double
    public let longitude: Double
    /// Metres.
    public let radius: Double
}
public enum GeofenceTransition: String { case enter, exit, dwell }

private struct GeofenceList: Decodable {
    struct Item: Decodable {
        struct Attributes: Decodable { let name: String; let latitude: Double; let longitude: Double; let radius: Double }
        let id: String
        let attributes: Attributes
    }
    let data: [Item]
}

extension Hermetica {
    /// The geofences configured for this site. Empty when the request fails or tracking is opted out.
    public static func fetchGeofences(completion: @escaping ([Geofence]) -> Void) {
        guard let core else { return completion([]) }
        core.fetchGeofences { completion($0 ?? []) }
    }

    /// Sends `$geofence_enter` / `_exit` / `_dwell` as a normal event, so event-triggered journeys fire on it.
    /// Use it when you run your own geofencing; `startGeofenceMonitoring` reports enter and exit by itself.
    public static func reportGeofence(_ transition: GeofenceTransition, geofenceId: String) {
        core?.enqueue("$geofence_\(transition.rawValue)", ["geofence_id": geofenceId])
    }

    #if os(iOS)
        /// Monitors the nearest fences with Core Location (iOS allows 20 regions per app, shared with your own). Never asks for
        /// permission: it works only once the app holds "Always" location access, and returns false otherwise.
        /// Call it at every launch (also in `application(_:didFinishLaunchingWithOptions:)`) so region events reach the SDK.
        @discardableResult
        public static func startGeofenceMonitoring() -> Bool {
            guard let core, !isTrackingOptedOut else { return false }
            let m = GeofenceMonitor.shared ?? GeofenceMonitor()
            GeofenceMonitor.shared = m
            return m.start(core)
        }

        /// Stops monitoring Hermetica's regions (the app's own regions are left alone).
        public static func stopGeofenceMonitoring() {
            DispatchQueue.main.async { GeofenceMonitor.shared?.stop() }
        }
    #endif
}

extension Core {
    static let regionPrefix = "hermetica:"
    static let regionLimit = 20

    /// nil when the request failed (keep monitoring what we have), [] when there are no fences.
    func fetchGeofences(done: @escaping ([Geofence]?) -> Void) {
        q.async {
            guard !self.optedOut else { return done([]) }
            self.transport.get("/client/geofences", []) { data in
                guard let data, let list = try? JSONDecoder().decode(GeofenceList.self, from: data) else { return done(nil) }
                done(list.data.map { Geofence(id: $0.id, name: $0.attributes.name, latitude: $0.attributes.latitude, longitude: $0.attributes.longitude, radius: $0.attributes.radius) })
            }
        }
    }

    /// A region event from Core Location: only Hermetica's own regions are reported.
    func handleRegion(_ identifier: String, _ t: GeofenceTransition) {
        guard identifier.hasPrefix(Self.regionPrefix) else { return }
        enqueue("$geofence_\(t.rawValue)", ["geofence_id": String(identifier.dropFirst(Self.regionPrefix.count))])
    }

    /// The `limit` fences closest to `location` (server order when the location is unknown).
    static func nearest(_ fences: [Geofence], to location: CLLocation?, limit: Int) -> [Geofence] {
        guard let location else { return Array(fences.prefix(limit)) }
        let d = { (f: Geofence) in location.distance(from: CLLocation(latitude: f.latitude, longitude: f.longitude)) - f.radius }
        return Array(fences.sorted { d($0) < d($1) }.prefix(limit))
    }
}

#if os(iOS)
    final class GeofenceMonitor: NSObject, CLLocationManagerDelegate {
        static var shared: GeofenceMonitor?
        private let manager = CLLocationManager()
        private weak var core: Core?

        override init() {
            super.init()
            manager.delegate = self
        }

        private var ours: [CLRegion] { manager.monitoredRegions.filter { $0.identifier.hasPrefix(Core.regionPrefix) } }

        func start(_ core: Core) -> Bool {
            guard CLLocationManager.authorizationStatus() == .authorizedAlways, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return false }
            self.core = core
            core.fetchGeofences { fences in
                guard let fences else { return }
                DispatchQueue.main.async { self.monitor(fences) }
            }
            return true
        }

        private func monitor(_ fences: [Geofence]) {
            let mine = ours
            let room = max(0, Core.regionLimit - (manager.monitoredRegions.count - mine.count))
            mine.forEach { manager.stopMonitoring(for: $0) }
            for f in Core.nearest(fences, to: manager.location, limit: room) {
                let r = CLCircularRegion(
                    center: CLLocationCoordinate2D(latitude: f.latitude, longitude: f.longitude),
                    radius: min(f.radius, manager.maximumRegionMonitoringDistance), identifier: Core.regionPrefix + f.id)
                r.notifyOnEntry = true
                r.notifyOnExit = true
                manager.startMonitoring(for: r)
            }
        }

        func stop() { ours.forEach { manager.stopMonitoring(for: $0) } }

        func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) { (core ?? Hermetica.core)?.handleRegion(region.identifier, .enter) }
        func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { (core ?? Hermetica.core)?.handleRegion(region.identifier, .exit) }
    }
#endif
