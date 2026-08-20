import XCTest
@testable import SteamPigeon

final class AttitudeTests: XCTestCase {

    /// Identity quaternion: the nose points along body +x, which in NED is due north
    /// and horizontal — inclination 90°, not 0°. Getting this backwards would put a
    /// rocket on the pad at "90°" and a horizontal one at "0°".
    func testIdentityIsHorizontalPointingNorth() {
        let q = Quaternionf(w: 1, x: 0, y: 0, z: 0)
        XCTAssertEqual(90, q.inclinationDeg, accuracy: 0.001)
        XCTAssertEqual(0, q.headingDeg, accuracy: 0.001)
    }

    /// Nose straight up: a **+90°** pitch about the body y axis.
    ///
    /// The sign is the thing to get right, and it is not guessable: `down` works out
    /// as −sin(θ), so a nose-UP attitude (negative down in NED) needs a POSITIVE
    /// rotation. 0° inclination is vertical, which is the reading on the pad.
    func testNoseUpIsZeroInclination() {
        let half = Float.pi / 4         // half of +90°
        let q = Quaternionf(w: cos(half), x: 0, y: sin(half), z: 0)
        XCTAssertEqual(0, q.inclinationDeg, accuracy: 0.01)
    }

    func testNoseDownIsOneEightyInclination() {
        let half = -Float.pi / 4
        let q = Quaternionf(w: cos(half), x: 0, y: sin(half), z: 0)
        XCTAssertEqual(180, q.inclinationDeg, accuracy: 0.01)
    }

    /// Yaw 90° about the down axis points the nose east.
    func testYawGivesACompassBearing() {
        let half = Float.pi / 4
        let q = Quaternionf(w: cos(half), x: 0, y: 0, z: sin(half))
        XCTAssertEqual(90, q.headingDeg, accuracy: 0.01)
    }

    /// Heading is reported 0–360, never negative — a "-90°" heading is unreadable.
    func testHeadingIsNeverNegative() {
        let half = -Float.pi / 4
        let q = Quaternionf(w: cos(half), x: 0, y: 0, z: sin(half))
        XCTAssertEqual(270, q.headingDeg, accuracy: 0.01)
    }

    /// An integrated attitude estimate is never exactly normalised, and a component
    /// fractionally past ±1 makes `acos` return NaN — which renders as "nan°" rather
    /// than failing loudly.
    func testSlightlyUnnormalisedQuaternionDoesNotProduceNaN() {
        let q = Quaternionf(w: 0.7072, x: 0, y: 0.7072, z: 0)    // just off unit length
        XCTAssertFalse(q.inclinationDeg.isNaN)
        XCTAssertFalse(q.headingDeg.isNaN)
        XCTAssertEqual(0, q.inclinationDeg, accuracy: 0.5)
    }

    func testSpeedMagnitude() {
        XCTAssertEqual(5, Vec3f(x: 3, y: 4, z: 0).magnitude, accuracy: 0.0001)
        XCTAssertEqual(0, Vec3f(x: 0, y: 0, z: 0).magnitude)
    }
}

final class MapScaleTests: XCTestCase {

    /// At the equator, zoom 0, MapLibre's convention gives ~78 km per point.
    func testEquatorZoomZero() {
        XCTAssertEqual(78271.51696,
                       MapScale.metersPerPoint(zoom: 0, latitude: 0), accuracy: 0.001)
    }

    /// Each zoom level halves the ground distance per point.
    func testEachZoomLevelHalves() {
        let z10 = MapScale.metersPerPoint(zoom: 10, latitude: 0)
        let z11 = MapScale.metersPerPoint(zoom: 11, latitude: 0)
        XCTAssertEqual(z10 / 2, z11, accuracy: 1e-9)
    }

    /// Latitude compresses the scale by cos(lat) — a bar that ignored this would read
    /// ~30% long in the Pacific Northwest.
    func testLatitudeCompressesTheScale() {
        let equator = MapScale.metersPerPoint(zoom: 15, latitude: 0)
        let seattle = MapScale.metersPerPoint(zoom: 15, latitude: 47.6)
        XCTAssertEqual(equator * cos(47.6 * .pi / 180), seattle, accuracy: 1e-9)
        XCTAssertLessThan(seattle, equator)
    }

    func testDevicePixelsDivideByScale() {
        let pts = MapScale.metersPerPoint(zoom: 15, latitude: 47)
        XCTAssertEqual(pts / 3, MapScale.metersPerDevicePixel(zoom: 15, latitude: 47, scale: 3),
                       accuracy: 1e-9)
    }

    /// The bar must show a round number someone can use, and must never exceed the
    /// width it was given.
    func testNiceScalePicksARoundNumberThatFits() throws {
        let mpp = 1.0
        let result = try XCTUnwrap(MapScale.niceScale(maxWidthPoints: 240, metersPerPoint: mpp))
        XCTAssertEqual(200, result.meters)
        XCTAssertLessThanOrEqual(result.widthPoints, 240)
    }

    func testNiceScaleUsesTheOneTwoFiveSequence() throws {
        for (maxMeters, expected) in [(120.0, 100.0), (260.0, 200.0), (700.0, 500.0),
                                      (1_100.0, 1_000.0), (9.0, 5.0)] {
            let r = try XCTUnwrap(MapScale.niceScale(maxWidthPoints: maxMeters, metersPerPoint: 1))
            XCTAssertEqual(expected, r.meters, "for a \(maxMeters) m span")
        }
    }

    func testDegenerateInputsYieldNothing() {
        XCTAssertNil(MapScale.niceScale(maxWidthPoints: 0, metersPerPoint: 1))
        XCTAssertNil(MapScale.niceScale(maxWidthPoints: 100, metersPerPoint: 0))
    }
}
