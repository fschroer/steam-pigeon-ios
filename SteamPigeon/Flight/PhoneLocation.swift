import Foundation
import CoreLocation
import CoreMotion

/// The phone's own position — one half of every distance and bearing the app quotes.
///
/// Deliberately thin. It publishes a position and an authorization state and nothing
/// else; the judgement about whether a resulting distance is believable lives in
/// `DistancePlausibility`, where it can be tested without a location fix.
final class PhoneLocation: NSObject, ObservableObject {

    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var horizontalAccuracyM: Double?
    @Published private(set) var authorized = false

    /// True-north heading. **CoreLocation applies declination itself**, which is the
    /// one part of ADR-0023 iOS does not need: Android converts the magnetic azimuth
    /// with `GeomagneticField` and caches it against a 10 km anchor, because its API
    /// hands back magnetic. `trueHeading` is already what the map's north-up camera
    /// and the locator bearing are both referenced to.
    @Published private(set) var trueHeadingDeg: Double?

    /// Effective compass trust after the ADR-0023 §4 hold.
    @Published private(set) var compassTrust: CompassTrust = .high

    private let manager = CLLocationManager()
    private let motion = CMMotionManager()
    private var hold = CompassTrustHold()

    /// Per-source verdicts. nil means "this source has never spoken" and must
    /// contribute NOTHING to the worst-of — a silent sensor voting healthy is the bug
    /// ADR-0023 saw reintroduced twice.
    private var headingSource: CompassTrust?
    private var fieldSource: CompassTrust?

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
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        startFieldMonitor()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        motion.stopMagnetometerUpdates()
    }

    /// ADR-0023 §3b: total field strength, the source that asks the physics rather
    /// than the vendor. Raw magnetometer — only the MAGNITUDE is used, never as a
    /// heading, so an uncalibrated hard-iron offset does not matter here.
    private func startFieldMonitor() {
        guard motion.isMagnetometerAvailable else { return }
        motion.magnetometerUpdateInterval = 0.2
        motion.startMagnetometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let f = data?.magneticField else { return }
            let magnitude = (f.x * f.x + f.y * f.y + f.z * f.z).squareRoot()
            self.fieldSource = FieldMagnitude.classify(magnitudeUt: magnitude)
            self.recomputeTrust()
        }
    }

    private func recomputeTrust() {
        let combined = CompassTrustHold.worstOf([headingSource, fieldSource]) ?? .high
        compassTrust = hold.update(combined)
    }

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

    func locationManager(_ m: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        trueHeadingAndTrust(newHeading)
    }

    /// iOS reports heading accuracy as a NUMBER of degrees, where Android exposes
    /// vendor flags — so this maps a different signal into ADR-0023's three levels
    /// rather than porting Android's flag handling, which has no counterpart here.
    /// A negative accuracy is CoreLocation's "invalid" sentinel.
    ///
    /// The 25° split is an iOS-specific judgement, not a value from the ADR, and is
    /// worth checking in the field: it is meant to sit above ordinary indoor
    /// wobble and below a heading anyone should act on.
    private func trueHeadingAndTrust(_ h: CLHeading) {
        trueHeadingDeg = h.trueHeading >= 0 ? h.trueHeading : nil
        let acc = h.headingAccuracy
        headingSource = acc < 0 ? .unreliable : (acc > 25 ? .low : .high)
        recomputeTrust()
    }

    /// iOS asks whether to show its own calibration HUD. Answer no: ADR-0023 puts the
    /// prompt on the map where the bearing being doubted is visible, and the system
    /// HUD would cover it.
    func locationManagerShouldDisplayHeadingCalibration(_ m: CLLocationManager) -> Bool { false }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // A failed update is not a reason to discard the last good position: the
        // distance it anchors is what the user is walking toward.
    }
}
