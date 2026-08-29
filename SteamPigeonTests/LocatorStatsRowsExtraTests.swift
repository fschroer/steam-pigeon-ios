import XCTest
import SwiftUI
@testable import SteamPigeon

/// The stats panel's two judgement calls: what colour the distance row is, and whether
/// the coordinates may be handed to a map app.
///
/// Both are Android's logic (`FlightMapScreen.kt`), and both are about **refusing to
/// assert more than the app knows** — which is why they are tested rather than eyeballed.
final class LocatorStatsRowsExtraTests: XCTestCase {

    // MARK: - Distance row colour

    /// The colour tracks the SENSOR, not the value, so it applies to "Unknown" exactly
    /// as it applies to a number. "Unknown" in the normal colour is the app declining to
    /// quote a figure from a healthy receiver; "Unknown" in red is the GPS being unwell,
    /// which is a thing to go and look at.
    func testTheDistanceRowIsErrorColouredWhenGpsIsUnwell() {
        XCTAssertEqual(SPColor.onBackground, LocatorStatsPanel.distanceColour(.ok))
        for unwell: SensorHealth in [.off, .initializing, .warning, .error, .stale] {
            XCTAssertEqual(SPColor.error, LocatorStatsPanel.distanceColour(unwell),
                           "\(unwell) is not healthy and the row must say so")
        }
    }

    /// Nil is healthy. Android's `RocketState` defaults `gpsStatus` to `Ok`, so a panel
    /// with no broadcast yet must not be painted as a fault.
    func testNoReadingYetIsNotAFault() {
        XCTAssertEqual(SPColor.onBackground, LocatorStatsPanel.distanceColour(nil))
    }

    // MARK: - Coordinate validity (Android's `validLatLng`)

    /// 0,0 is what a locator reports before it has a fix — a real place in the Atlantic,
    /// and never where the rocket is.
    func testTheNullIslandFixIsNotACoordinate() {
        XCTAssertFalse(LocatorStatsPanel.validCoordinate(0, 0))
    }

    func testOutOfRangeAndNonFiniteCoordinatesAreRejected() {
        XCTAssertFalse(LocatorStatsPanel.validCoordinate(91, 0))
        XCTAssertFalse(LocatorStatsPanel.validCoordinate(0, 181))
        XCTAssertFalse(LocatorStatsPanel.validCoordinate(.nan, 10))
        XCTAssertFalse(LocatorStatsPanel.validCoordinate(10, .infinity))
    }

    /// A real fix, including the cases where exactly one component is zero — the equator
    /// and the prime meridian are places too.
    func testARealFixIsAccepted() {
        XCTAssertTrue(LocatorStatsPanel.validCoordinate(37.7749, -122.4194))
        XCTAssertTrue(LocatorStatsPanel.validCoordinate(0, -122.4194))
        XCTAssertTrue(LocatorStatsPanel.validCoordinate(37.7749, 0))
        XCTAssertTrue(LocatorStatsPanel.validCoordinate(90, 180))
    }

    // MARK: - The row itself

    /// "Unknown" carries neither the padding nor the unit: "Unknown m" would be a
    /// measurement in metres of something unknown, which is not what is being said.
    func testTheUnknownRowHasNoUnits() {
        XCTAssertEqual("Dist: Unknown", LocatorStatsPanel.distanceRow(nil))
        XCTAssertTrue(LocatorStatsPanel.distanceRow(412).hasSuffix(" m"))
    }
}
