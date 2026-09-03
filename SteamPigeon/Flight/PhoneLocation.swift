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

    /// How far the phone is pitched from upright, degrees. Drives the follow-device
    /// tilt mode: raise the phone toward the horizon and the map leans with it.
    @Published private(set) var devicePitchDeg: Double?

    /// True-north bearing the BACK CAMERA is pointing along, for the landscape AR
    /// overlay. Nil when the sight is not on screen, and nil when the attitude stream has
    /// no true-north reference frame to work from — the same "no bearing to be had" the
    /// overlay already suppresses for.
    ///
    /// Kept apart from `trueHeadingDeg` for the reason Android keeps
    /// `handheldCameraAzimuth` apart from `handheldDeviceAzimuth`: the heading is the
    /// direction the top of the phone points, which is 90° off in landscape and
    /// degenerate with the phone held up at the sky.
    @Published private(set) var cameraAzimuthDeg: Double?

    /// Elevation of the back camera above the horizon, degrees, positive looking up —
    /// Android's `handheldDevicePitch`. Signed, and NOT `devicePitchDeg`, which is
    /// unsigned and measured about a different axis.
    @Published private(set) var cameraElevationDeg: Double?

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
        startAttitudeMonitor()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        motion.stopDeviceMotionUpdates()
    }

    /// Whether the landscape AR sight is on screen. It asks for two things the rest of
    /// the app does not, and both are scoped to it — see `startAttitudeMonitor`.
    private var cameraSensing = false

    /// The AR sight is up: north-reference the attitude, and sample faster.
    func beginCameraSensing() {
        guard !cameraSensing else { return }
        cameraSensing = true
        startAttitudeMonitor()
    }

    /// Back to the configuration the map runs on.
    func endCameraSensing() {
        guard cameraSensing else { return }
        cameraSensing = false
        cameraAzimuthDeg = nil
        cameraElevationDeg = nil
        startAttitudeMonitor()
    }

    /// One device-motion stream, carrying three things: the follow-device tilt, the AR
    /// sight's boresight, and ADR-0023 §3b's field magnitude.
    ///
    /// **The reference frame is north-referenced wherever the hardware allows it, and
    /// that is not the sight's requirement — it is the compass's.** `magneticField` is
    /// published as a *calibrated* field only while device motion runs a magnetic or
    /// true-north frame, and the calibrated field is the whole of ADR-0023 §3b on iOS:
    /// the raw magnetometer this used to read carries the phone's own hard-iron offset,
    /// which held the ∞ mark permanently red on a device whose heading was fine. True
    /// north is preferred because the sight also differences the camera's bearing against
    /// a true-north bearing — the need Android meets with `GeomagneticField` — and
    /// magnetic north still serves the compass when there is no fix to convert with.
    ///
    /// **The rate is what the sight scopes.** 60 ms is what Android registers at
    /// (`SENSOR_DELAY_UI`), and its comment says why it did not ask for more: every sample
    /// there recomposes the whole map screen. That cost does not exist on the iOS sight —
    /// in landscape the map is not mounted and what redraws is one `Canvas` — and 10 Hz
    /// was reported from the phone as visibly stepped against Android. So the sight
    /// samples at 60 Hz and the map keeps the 10 Hz it was verified at.
    private func startAttitudeMonitor() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.stopDeviceMotionUpdates()
        motion.deviceMotionUpdateInterval = cameraSensing ? 1.0 / 60 : 0.1

        let available = CMMotionManager.availableAttitudeReferenceFrames()
        let trueNorth = available.contains(.xTrueNorthZVertical)
        let frame: CMAttitudeReferenceFrame =
            trueNorth ? .xTrueNorthZVertical
                      : (available.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical
                                                                      : .xArbitraryZVertical)

        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            // 0 is flat on a table, 90 is upright. Android measures from upright, so
            // this reports the same way.
            self.devicePitchDeg = 90 - abs(data.attitude.pitch * 180 / .pi)

            // Silent under `.xArbitraryZVertical`, where the field is not calibrated and
            // `CalibratedField` says so by returning nil — a source that cannot speak
            // must not vote.
            self.fieldSource = CalibratedField.classify(data.magneticField)
            self.recomputeTrust()

            // Only true north gives a bearing the locator's can be differenced against.
            guard trueNorth, self.cameraSensing else { return }
            self.cameraElevationDeg = CameraBoresight.elevationDeg(gravity: data.gravity)
            self.cameraAzimuthDeg = CameraBoresight.azimuthDeg(
                rotation: data.attitude.rotationMatrix, gravity: data.gravity)
        }
    }

    /// **Assigned only on a change.** The verdict is recomputed on every attitude sample,
    /// which is 60 a second while the sight is up; republishing an unchanged value would
    /// invalidate every view observing this object at that rate for nothing.
    private func recomputeTrust() {
        let combined = CompassTrustHold.worstOf([headingSource, fieldSource]) ?? .high
        let effective = hold.update(combined)
        if effective != compassTrust { compassTrust = effective }
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
