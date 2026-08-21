import XCTest
import CoreLocation
@testable import SteamPigeon

/// The per-frame camera filter.
///
/// The behaviour worth pinning is not "it moves toward the target" but that it
/// **settles** — a filter with no deadband tracks a random walk faithfully, just
/// smoothly, and the map creeps under a stationary rocket forever. These run whole
/// sequences of frames rather than checking one step.
final class CameraFilterTests: XCTestCase {

    private let pad = CLLocationCoordinate2D(latitude: 47.0, longitude: -122.0)

    private func inputs(rocket: CLLocationCoordinate2D?,
                        phone: CLLocationCoordinate2D? = nil,
                        fit: (CLLocationCoordinate2D, Double)? = nil,
                        autoCentre: Bool = true,
                        autoZoom: Bool = false,
                        maxZoom: Double = 20,
                        pitch: Double = 0,
                        locatorAccuracyM: Double = 3,
                        phoneAccuracyM: Double? = 5) -> CameraInputs {
        CameraInputs(fit: fit.map { (centre: $0.0, zoom: $0.1) },
                     rocket: rocket, phone: phone,
                     locatorAccuracyM: locatorAccuracyM, phoneAccuracyM: phoneAccuracyM,
                     autoCentre: autoCentre, autoZoom: autoZoom, maxZoom: maxZoom,
                     targetPitch: pitch, viewportWidthPx: 1170, screenScale: 3)
    }

    private func seeded(at centre: CLLocationCoordinate2D, zoom: Double = 15) -> CameraFilter {
        var f = CameraFilter()
        f.seed(centre: centre, zoom: zoom, pitch: 0)
        return f
    }

    /// Nothing happens until the filter has been told where the camera is. Otherwise the
    /// first frame drags in from 0,0 — null island — at 10% a frame.
    func testAnUnseededFilterDoesNothing() {
        var f = CameraFilter()
        XCTAssertNil(f.tick(inputs(rocket: pad)))
    }

    func testItConvergesOnTheTarget() {
        let target = CLLocationCoordinate2D(latitude: 47.01, longitude: -122.0)
        var f = seeded(at: pad)
        var last: CameraSolution?
        for _ in 0..<400 { last = f.tick(inputs(rocket: target)) }
        let solution = try? XCTUnwrap(last)
        XCTAssertEqual(target.latitude, solution!.centre.latitude, accuracy: 1e-6)
    }

    /// The point of the deadband. A rocket lying still, reporting GPS noise every fix,
    /// must leave the camera completely stationary — not merely moving slowly.
    func testAStationaryRocketWithNoisyFixesStopsTheCameraDead() {
        var f = seeded(at: pad)
        // Converge on the pad first.
        for _ in 0..<400 { _ = f.tick(inputs(rocket: pad)) }
        let settled = f.tick(inputs(rocket: pad))!

        // ~2 m of jitter, well inside the ~8 m band for a 3 m/5 m pair.
        var rng = SystemRandomNumberGenerator()
        var moved = 0.0
        for _ in 0..<600 {
            let jitter = CLLocationCoordinate2D(
                latitude: pad.latitude + Double.random(in: -0.00002...0.00002, using: &rng),
                longitude: pad.longitude + Double.random(in: -0.00002...0.00002, using: &rng))
            let s = f.tick(inputs(rocket: jitter))!
            moved = max(moved, CameraFraming.metersBetween(
                (settled.centre.latitude, settled.centre.longitude),
                (s.centre.latitude, s.centre.longitude)))
        }
        XCTAssertLessThan(moved, 0.5, "the camera crept under a stationary rocket")
    }

    /// And it must still follow a rocket that actually moves — the failure on the other
    /// side of the deadband is a map that has quietly stopped tracking.
    func testItStillFollowsRealMovement() {
        var f = seeded(at: pad)
        for _ in 0..<400 { _ = f.tick(inputs(rocket: pad)) }
        let moved = CLLocationCoordinate2D(latitude: pad.latitude + 0.005, longitude: pad.longitude)
        var last: CameraSolution?
        for _ in 0..<400 { last = f.tick(inputs(rocket: moved)) }
        XCTAssertEqual(moved.latitude, last!.centre.latitude, accuracy: 1e-5)
    }

    /// Auto-centre off means the camera is the user's. Not "followed more loosely".
    func testAutoCentreOffLeavesTheCentreAlone() {
        var f = seeded(at: pad)
        let away = CLLocationCoordinate2D(latitude: 48, longitude: -122)
        var last: CameraSolution?
        for _ in 0..<200 { last = f.tick(inputs(rocket: away, autoCentre: false)) }
        XCTAssertEqual(pad.latitude, last!.centre.latitude, accuracy: 1e-12)
    }

    // MARK: - Zoom

    /// The closest-zoom limit binds AUTO-zoom and nothing else.
    func testAutoZoomIsBoundedByTheClosestZoomSetting() {
        var f = seeded(at: pad, zoom: 15)
        var last: CameraSolution?
        for _ in 0..<600 {
            last = f.tick(inputs(rocket: pad, phone: pad, fit: (pad, 30),
                                 autoZoom: true, maxZoom: 20))
        }
        XCTAssertLessThanOrEqual(last!.zoom, 20 + 1e-9)
    }

    /// With auto-zoom OFF the limit must not claw back a manual pinch: the gesture seeds
    /// the filter from the live camera, so clamping unconditionally would undo the pinch
    /// the moment the backoff expired, with nothing on screen to explain it.
    func testAManualZoomPastTheLimitIsNotClawedBack() {
        var f = seeded(at: pad, zoom: 22)
        var last: CameraSolution?
        for _ in 0..<200 {
            last = f.tick(inputs(rocket: pad, phone: pad, fit: (pad, 30),
                                 autoZoom: false, maxZoom: 20))
        }
        XCTAssertEqual(22, last!.zoom, accuracy: 1e-9)
    }

    /// Tilt gives zoom away so a leaned camera frames the same ground, and the
    /// correction must not feed back into the next frame.
    func testTiltCorrectionIsAppliedOnTheWayOutOnly() {
        var f = seeded(at: pad, zoom: 18)
        var last: CameraSolution?
        for _ in 0..<600 { last = f.tick(inputs(rocket: pad, pitch: 45)) }
        XCTAssertEqual(45, last!.pitch, accuracy: 0.5)
        XCTAssertEqual(18 - CameraFilter.zoomCorrection(forPitch: last!.pitch), last!.zoom,
                       accuracy: 1e-6)
    }

    /// Seeding is what a gesture does. It must adopt the live camera AND drop the
    /// anchors — a pan moves the camera somewhere the old anchor knows nothing about,
    /// and keeping it would leave the map parked off the rocket with nothing to explain
    /// it.
    func testSeedingDropsTheAnchors() {
        var f = seeded(at: pad)
        for _ in 0..<200 { _ = f.tick(inputs(rocket: pad)) }
        XCTAssertNotNil(f.anchorCentre)
        let elsewhere = CLLocationCoordinate2D(latitude: 40, longitude: -100)
        f.seed(centre: elsewhere, zoom: 12, pitch: 0)
        XCTAssertNil(f.anchorCentre)
        XCTAssertNil(f.anchorZoom)
        let s = f.tick(inputs(rocket: pad, autoCentre: false))!
        XCTAssertEqual(elsewhere.latitude, s.centre.latitude, accuracy: 1e-12)
    }
}
