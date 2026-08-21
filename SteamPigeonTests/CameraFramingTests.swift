import XCTest
@testable import SteamPigeon

/// The auto-camera's sizing, ported from Android's `AutoCenterDeadbandTest` and
/// `AutoZoomDeadbandTest`.
///
/// Both receivers keep issuing fresh fixes while nothing is moving, so the framed centre
/// wanders a few metres a second forever and the fitted zoom breathes with it. A filter
/// with no deadband tracks that faithfully, just smoothly — the imagery creeps under a
/// rocket lying still in a field. These pin the sizing that stops it.
final class CameraFramingTests: XCTestCase {

    // MARK: - Centring band

    /// 2·√2·σ_target with σ_target = ½·√(σ_locator² + σ_phone²): the camera targets the
    /// point between the two, which moves half as far as they do, and the anchor it is
    /// measured against is itself a noisy sample.
    func testBothFixesFramedGivesTheMidpointFormula() {
        let expected = 2 * 2.0.squareRoot() * 0.5 * (9.0 + 25.0).squareRoot()
        XCTAssertEqual(expected,
                       CameraFraming.recenterDeadbandM(locatorAccuracyM: 3, phoneAccuracyM: 5),
                       accuracy: 1e-9)
        // Magnitude sanity, so a refactor that loses a factor shows as more than the
        // formula restated twice: a good fix at both ends is ~8 m.
        XCTAssertEqual(8.25,
                       CameraFraming.recenterDeadbandM(locatorAccuracyM: 3, phoneAccuracyM: 5),
                       accuracy: 0.05)
    }

    /// nil phone accuracy means the phone is not part of the framing, so the target is
    /// the rocket itself and carries the locator's full error — no halving.
    func testARocketOnlyTargetCarriesTheFullLocatorError() {
        let withPhone = CameraFraming.recenterDeadbandM(locatorAccuracyM: 6, phoneAccuracyM: 0)
        let rocketOnly = CameraFraming.recenterDeadbandM(locatorAccuracyM: 6, phoneAccuracyM: nil)
        XCTAssertEqual(2 * 2.0.squareRoot() * 6, rocketOnly, accuracy: 1e-9)
        XCTAssertGreaterThan(rocketOnly, withPhone, "the midpoint halving must not apply")
    }

    func testTheBandIsClamped() {
        XCTAssertEqual(CameraFraming.recenterDeadbandMinM,
                       CameraFraming.recenterDeadbandM(locatorAccuracyM: 0, phoneAccuracyM: 0))
        XCTAssertEqual(CameraFraming.recenterDeadbandMaxM,
                       CameraFraming.recenterDeadbandM(locatorAccuracyM: 500, phoneAccuracyM: 500))
    }

    /// Non-finite and negative accuracies mean "not reported" and must not produce a
    /// NaN band — a NaN comparison is false, so the anchor would never re-latch and the
    /// map would silently stop following the rocket.
    func testNonsenseAccuraciesFallBackToTheFloor() {
        for bad in [Double.nan, .infinity, -1] {
            let band = CameraFraming.recenterDeadbandM(locatorAccuracyM: bad, phoneAccuracyM: bad)
            XCTAssertTrue(band.isFinite, "\(bad) produced a non-finite band")
            XCTAssertEqual(CameraFraming.recenterDeadbandMinM, band)
        }
    }

    // MARK: - Viewport cap

    /// The cap is exactly the margin the bounds fit reserves outside the two markers.
    /// Reported from the field as "the locator or the phone would be off screen".
    func testTheBandIsCappedByWhatIsOnScreen() {
        // 400 px of viewport at 0.05 m/px = 20 m of ground; 14% of that is 2.8 m.
        let capped = CameraFraming.viewportLimitedDeadbandM(40, viewportWidthPx: 400,
                                                            metersPerDevicePixel: 0.05)
        XCTAssertEqual(2.8, capped, accuracy: 1e-9)
    }

    /// The cap outranks the floor: a screen showing less ground than the floor is a
    /// different situation, and there the floor is the thing that is wrong.
    func testTheCapOutranksTheFloor() {
        let capped = CameraFraming.viewportLimitedDeadbandM(CameraFraming.recenterDeadbandMinM,
                                                            viewportWidthPx: 400,
                                                            metersPerDevicePixel: 0.01)
        XCTAssertLessThan(capped, CameraFraming.recenterDeadbandMinM)
    }

    /// Before the map has been measured there is nothing to cap against, and a zero
    /// viewport must not collapse the band to zero — that would re-latch on every fix.
    func testAnUnmeasuredViewportLeavesTheBandAlone() {
        XCTAssertEqual(40, CameraFraming.viewportLimitedDeadbandM(40, viewportWidthPx: 0,
                                                                  metersPerDevicePixel: 0.05))
        XCTAssertEqual(40, CameraFraming.viewportLimitedDeadbandM(40, viewportWidthPx: 400,
                                                                  metersPerDevicePixel: 0))
    }

    // MARK: - Zoom band

    /// σ_separation / (D·ln2), with no halving: separation is a difference between the
    /// two fixes, so both errors land on it at full weight.
    func testTheZoomBandIsTheLogDerivativeOfTheSeparationError() {
        let sigma = (9.0 + 25.0).squareRoot()
        let expected = 2 * 2.0.squareRoot() * sigma / (50 * log(2.0))
        XCTAssertEqual(expected,
                       CameraFraming.autoZoomDeadbandLevels(locatorAccuracyM: 3, phoneAccuracyM: 5,
                                                            separationM: 50),
                       accuracy: 1e-9)
    }

    /// Self-scaling: the same metres of error is most of a zoom level when the fixes are
    /// close together and nothing at all when they are far apart.
    func testTheBandNarrowsAsTheSeparationGrows() {
        let near = CameraFraming.autoZoomDeadbandLevels(locatorAccuracyM: 3, phoneAccuracyM: 5,
                                                        separationM: 10)
        let far = CameraFraming.autoZoomDeadbandLevels(locatorAccuracyM: 3, phoneAccuracyM: 5,
                                                       separationM: 1000)
        XCTAssertGreaterThan(near, far)
        XCTAssertEqual(CameraFraming.autoZoomDeadbandMinLevels, far)
    }

    /// An unknown separation is not evidence that the zoom should move, so it yields the
    /// widest band rather than the narrowest.
    func testAnUnknownSeparationWidensTheBand() {
        for bad in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(CameraFraming.autoZoomDeadbandMaxLevels,
                           CameraFraming.autoZoomDeadbandLevels(locatorAccuracyM: 3,
                                                                phoneAccuracyM: 5,
                                                                separationM: bad))
        }
    }

    // MARK: - Ground geometry

    /// MapLibre reports zoom in the 512-px-tile convention, so metres per point is half
    /// the Google figure at the same zoom. Getting this wrong made Android's scale bar
    /// overstate by 2.4×.
    func testMetersPerPointAtTheEquator() {
        // 78271.51696 IS the halved constant — 156543.03392 / 2 — so it is the value at
        // zoom 0, not something to halve again.
        XCTAssertEqual(78271.51696, CameraFraming.metersPerPoint(zoom: 0, latitude: 0),
                       accuracy: 1e-6)
        XCTAssertEqual(156543.03392 / 2, CameraFraming.metersPerPoint(zoom: 0, latitude: 0),
                       accuracy: 1e-6)
        XCTAssertEqual(CameraFraming.metersPerPoint(zoom: 0, latitude: 0) / 2,
                       CameraFraming.metersPerPoint(zoom: 1, latitude: 0), accuracy: 1e-9)
    }

    func testDevicePixelsDivideByTheScreenScale() {
        XCTAssertEqual(CameraFraming.metersPerPoint(zoom: 18, latitude: 47) / 3,
                       CameraFraming.metersPerDevicePixel(zoom: 18, latitude: 47, scale: 3),
                       accuracy: 1e-12)
    }

    func testMetersBetweenMatchesAKnownSeparation() {
        // 0.001° of latitude is ~111.3 m anywhere.
        let d = CameraFraming.metersBetween((47.0, -122.0), (47.001, -122.0))
        XCTAssertEqual(111.3, d, accuracy: 0.5)
    }

    /// A pair straddling the antimeridian measures the short way round, not most of the
    /// way about the planet.
    func testMetersBetweenWrapsTheAntimeridian() {
        let d = CameraFraming.metersBetween((0, 179.999), (0, -179.999))
        XCTAssertLessThan(d, 500)
    }

    /// A small or not-yet-measured viewport must not ask for padding that meets in the
    /// middle — the fit degenerates and zooms far out when it does.
    func testPaddingCannotMeetInTheMiddle() {
        let tiny = CameraFraming.boundsFitPadding(viewportWidth: 4, viewportHeight: 4)
        XCTAssertLessThan(tiny.h * 2, 4)
        XCTAssertLessThan(tiny.v * 2, 4)
        let unmeasured = CameraFraming.boundsFitPadding(viewportWidth: 0, viewportHeight: 0)
        XCTAssertEqual(0, unmeasured.h)
        XCTAssertEqual(0, unmeasured.v)
    }
}
