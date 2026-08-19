import Foundation
import CoreLocation

/// The phone's own position — one half of every distance and bearing the app quotes.
///
/// Deliberately thin. It publishes a position and an authorization state and nothing
/// else; the judgement about whether a resulting distance is believable lives in
/// `DistancePlausibility`, where it can be tested without a location fix.
final class PhoneLocation: NSObject, ObservableObject {

    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var horizontalAccuracyM: Double?
    @Published private(set) var authorized = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Recovery is a walking-pace activity; this keeps updates coming while the
        // user paces a field rather than filtering them out as noise.
        manager.distanceFilter = 2
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    /// True when the phone's own fix is good enough to anchor a bearing. A position
    /// with a 500 m accuracy circle produces a bearing that is worse than no bearing.
    var hasUsableFix: Bool {
        guard let acc = horizontalAccuracyM else { return false }
        return coordinate != nil && acc > 0 && acc <= 100
    }
}

extension PhoneLocation: CLLocationManagerDelegate {

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        coordinate = l.coordinate
        horizontalAccuracyM = l.horizontalAccuracy
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            authorized = true
            m.startUpdatingLocation()
        default:
            authorized = false
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // A failed update is not a reason to discard the last good position: the
        // distance it anchors is what the user is walking toward.
    }
}
