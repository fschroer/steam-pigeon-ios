import XCTest
@testable import SteamPigeon

/// The landscape AR sight's geometry, ported with `CameraPreviewScreen`.
///
/// None of this can be checked by looking: the simulator has no compass, so the overlay
/// never moves there, and on a phone a marker that is confidently in the wrong place
/// looks exactly like one in the right place. These pin the arithmetic instead.
final class ARSightTests: XCTestCase {

    // MARK: - Deltas

    /// Right of the aim is positive, and a pair straddling north takes the short way
    /// round rather than reading as a 340° swing.
    func testHorizontalDeltaTakesTheShortWayAcrossNorth() {
        XCTAssertEqual(20, ARSight.horizontalDeltaDeg(locatorAzimuthDeg: 10,
                                                      cameraAzimuthDeg: 350), accuracy: 1e-9)
        XCTAssertEqual(-20, ARSight.horizontalDeltaDeg(locatorAzimuthDeg: 350,
                                                       cameraAzimuthDeg: 10), accuracy: 1e-9)
        XCTAssertEqual(0, ARSight.horizontalDeltaDeg(locatorAzimuthDeg: 123,
                                                     cameraAzimuthDeg: 123), accuracy: 1e-9)
    }

    /// Positive means the locator is BELOW the aim, because that is the direction the
    /// canvas Y axis grows: aiming 30° up at a rocket 5° above the horizon leaves it 25°
    /// down the screen.
    func testVerticalDeltaIsPositiveWhenTheLocatorSitsBelowTheAim() {
        XCTAssertEqual(25, ARSight.verticalDeltaDeg(cameraElevationDeg: 30,
                                                    locatorElevationDeg: 5), accuracy: 1e-9)
        XCTAssertEqual(-15, ARSight.verticalDeltaDeg(cameraElevationDeg: 10,
                                                     locatorElevationDeg: 25), accuracy: 1e-9)
    }

    /// A locator elevation arrives wrapped into 0…360 (`LocatorVector` adds 360 before
    /// its modulo), so a rocket 5° BELOW the horizon reads as 355 — and the delta has to
    /// come out as if it read −5.
    func testWrappedLocatorElevationBehavesLikeItsSignedForm() {
        XCTAssertEqual(ARSight.verticalDeltaDeg(cameraElevationDeg: 10, locatorElevationDeg: -5),
                       ARSight.verticalDeltaDeg(cameraElevationDeg: 10, locatorElevationDeg: 355),
                       accuracy: 1e-9)
    }

    // MARK: - Marker placement

    private let screen = CGSize(width: 800, height: 400)

    /// Ten DEVICE pixels per degree, which is Android's `scale = 10f` on a canvas
    /// measured in pixels. Taking it as points would swing the marker ~3× too far.
    func testPointsPerDegreeIsTenDevicePixels() {
        XCTAssertEqual(10.0 / 3, ARSight.pointsPerDegree(screenScale: 3), accuracy: 1e-9)
        XCTAssertEqual(5, ARSight.pointsPerDegree(screenScale: 2), accuracy: 1e-9)
    }

    func testZeroDeltaPutsTheRingOnTheCrosshair() {
        guard case .circle(let centre) = ARSight.marker(horizontalDeltaDeg: 0,
                                                        verticalDeltaDeg: 0,
                                                        size: screen, pointsPerDegree: 10) else {
            return XCTFail("expected a ring at the centre")
        }
        XCTAssertEqual(400, centre.x, accuracy: 1e-9)
        XCTAssertEqual(200, centre.y, accuracy: 1e-9)
    }

    /// Right and down are positive, and the deflection is the delta times the scale.
    func testMarkerDeflectsRightAndDown() {
        guard case .circle(let centre) = ARSight.marker(horizontalDeltaDeg: 12,
                                                        verticalDeltaDeg: -8,
                                                        size: screen, pointsPerDegree: 10) else {
            return XCTFail("expected a ring on screen")
        }
        XCTAssertEqual(400 + 120, centre.x, accuracy: 1e-9)
        XCTAssertEqual(200 - 80, centre.y, accuracy: 1e-9)
    }

    /// A ring is still drawn one whole radius off screen — it is the part of the ring
    /// that is still visible that says which way to turn.
    func testRingSurvivesUntilItIsAFullRadiusOffScreen() {
        // 41° right of a 400 pt half-width at 10 pt/° lands the centre 10 pt outside.
        guard case .circle = ARSight.marker(horizontalDeltaDeg: 41, verticalDeltaDeg: 0,
                                            size: screen, pointsPerDegree: 10) else {
            return XCTFail("expected a ring")
        }
        guard case .edgeArrow = ARSight.marker(horizontalDeltaDeg: 46, verticalDeltaDeg: 0,
                                               size: screen, pointsPerDegree: 10) else {
            return XCTFail("expected an arrow once the ring is a full radius out")
        }
    }

    /// The arrow sits a margin in from the edge it was clamped to, and points at the
    /// locator — not along the axis it went off.
    func testEdgeArrowIsClampedAndPointsAtTheLocator() {
        guard case .edgeArrow(let base, let direction) =
                ARSight.marker(horizontalDeltaDeg: 90, verticalDeltaDeg: 90,
                               size: screen, pointsPerDegree: 10) else {
            return XCTFail("expected an arrow")
        }
        XCTAssertEqual(800 - ARSight.edgeMargin, base.x, accuracy: 1e-9)
        XCTAssertEqual(400 - ARSight.edgeMargin, base.y, accuracy: 1e-9)
        // Off the bottom-right corner: both components positive, and a unit vector.
        XCTAssertGreaterThan(direction.dx, 0)
        XCTAssertGreaterThan(direction.dy, 0)
        XCTAssertEqual(1, (direction.dx * direction.dx + direction.dy * direction.dy).squareRoot(),
                       accuracy: 1e-9)
    }

    /// Straight up: the arrow rides the top edge at the crosshair's column, pointing up.
    func testEdgeArrowOnASingleAxisStaysOnTheCentreLine() {
        guard case .edgeArrow(let base, let direction) =
                ARSight.marker(horizontalDeltaDeg: 0, verticalDeltaDeg: -60,
                               size: screen, pointsPerDegree: 10) else {
            return XCTFail("expected an arrow")
        }
        XCTAssertEqual(400, base.x, accuracy: 1e-9)
        XCTAssertEqual(ARSight.edgeMargin, base.y, accuracy: 1e-9)
        XCTAssertEqual(0, direction.dx, accuracy: 1e-9)
        XCTAssertEqual(-1, direction.dy, accuracy: 1e-9)
    }
}
