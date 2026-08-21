import XCTest
import CoreLocation
@testable import SteamPigeon

/// Heading-up rotation smoothing.
///
/// Reported from the phone as "very jerky". CoreLocation smooths the heading VALUE but
/// delivers it in discrete updates a few times a second, while the camera is written
/// every display frame — so the bearing was held for ~20 frames and then stepped.
final class CameraBearingTests: XCTestCase {

    private let pad = CLLocationCoordinate2D(latitude: 47, longitude: -122)

    private func inputs(heading: Double?) -> CameraInputs {
        CameraInputs(fit: nil, rocket: nil, phone: nil, locatorAccuracyM: 3,
                     phoneAccuracyM: 5, autoCentre: false, autoZoom: false, maxZoom: 20,
                     targetPitch: 0, viewportWidthPx: 1170, screenScale: 3,
                     headingDeg: heading)
    }

    private func seeded() -> CameraFilter {
        var f = CameraFilter()
        f.seed(centre: pad, zoom: 15, pitch: 0)
        return f
    }

    /// Adopted, not wound round to. Enabling heading-up must not spin the map from
    /// north at 1% a frame.
    func testTheFirstHeadingIsAdoptedOutright() {
        var f = seeded()
        XCTAssertEqual(200, f.tick(inputs(heading: 200))!.bearing!, accuracy: 1e-9)
    }

    /// The point of the fix: a step in the reported heading becomes a glide.
    func testASteppedHeadingIsSmoothed() {
        var f = seeded()
        _ = f.tick(inputs(heading: 0))
        let firstFrame = f.tick(inputs(heading: 90))!.bearing!
        XCTAssertEqual(0.9, firstFrame, accuracy: 0.01, "one frame must move ~1% of the step")

        for _ in 0..<600 { _ = f.tick(inputs(heading: 90)) }
        XCTAssertEqual(90, f.tick(inputs(heading: 90))!.bearing!, accuracy: 0.5)
    }

    /// Crossing north must take the short way. Without the ±540 wrap the camera spins
    /// 359° to go one degree, which is its own kind of jerk.
    func testItTurnsTheShortWayAcrossNorth() {
        XCTAssertEqual(2, CameraFilter.shortestTurn(from: 359, to: 1), accuracy: 1e-9)
        XCTAssertEqual(-2, CameraFilter.shortestTurn(from: 1, to: 359), accuracy: 1e-9)
        XCTAssertEqual(180, abs(CameraFilter.shortestTurn(from: 0, to: 180)), accuracy: 1e-9)

        var f = seeded()
        _ = f.tick(inputs(heading: 359))
        let next = f.tick(inputs(heading: 1))!.bearing!
        // Moved a fraction of 2°, forward through 360 — not backward through 358.
        XCTAssertTrue(next > 359 || next < 1, "took the long way: \(next)")
    }

    /// The output stays in 0..<360 however many turns it accumulates.
    func testTheBearingStaysInRange() {
        var f = seeded()
        _ = f.tick(inputs(heading: 350))
        for _ in 0..<2000 {
            let b = f.tick(inputs(heading: 10))!.bearing!
            XCTAssertTrue(b >= 0 && b < 360, "out of range: \(b)")
        }
    }

    /// Heading-up off means the camera's rotation is the user's, and re-enabling adopts
    /// the live heading rather than resuming from a stale one.
    func testTurningItOffForgetsTheSmoothedValue() {
        var f = seeded()
        _ = f.tick(inputs(heading: 200))
        XCTAssertNil(f.tick(inputs(heading: nil))!.bearing)
        XCTAssertEqual(20, f.tick(inputs(heading: 20))!.bearing!, accuracy: 1e-9)
    }
}
