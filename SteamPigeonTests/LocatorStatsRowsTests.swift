import XCTest
@testable import SteamPigeon

/// The two stats-panel rows whose wording is a port decision rather than a format
/// string, both reported from the phone on 2026-08-21.
///
/// Neither is arithmetic, so neither could fail a test before this file existed — and
/// both are exactly the kind of detail the parity rule is about: the panel showed
/// "Unknown m", and it named flight states by their Swift case rather than by the words
/// Android writes.
final class LocatorStatsRowsTests: XCTestCase {

    // MARK: - Distance

    func testDistanceRowRightJustifiesTheNumberInAFifteenWideField() {
        XCTAssertEqual(LocatorStatsPanel.distanceRow(412),
                       "Dist:             412 m")
        XCTAssertEqual(LocatorStatsPanel.distanceRow(0),
                       "Dist:               0 m")
    }

    /// A withheld distance is a word, not a measurement: no field padding, and above
    /// all **no unit**. "Unknown m" reads as a distance in metres that happens to be
    /// unknown, when the point is that the app will not quote one at all.
    func testUnknownDistanceCarriesNoUnits() {
        XCTAssertEqual(LocatorStatsPanel.distanceRow(nil), "Dist: Unknown")
        XCTAssertFalse(LocatorStatsPanel.distanceRow(nil).hasSuffix(" m"))
    }

    // MARK: - Flight state

    /// Android's `LocatorStats` maps every state to display text by hand. These are
    /// those words, in wire order.
    func testFlightStateLabelsAreAndroidsWords() {
        XCTAssertEqual(FlightStates.waitingLaunch.panelLabel, "Waiting For Launch")
        XCTAssertEqual(FlightStates.launched.panelLabel, "Launched")
        XCTAssertEqual(FlightStates.burnout.panelLabel, "Burnout")
        XCTAssertEqual(FlightStates.noseover.panelLabel, "Noseover")
        XCTAssertEqual(FlightStates.droguePrimaryEvent.panelLabel, "Drogue Primary")
        XCTAssertEqual(FlightStates.drogueBackupEvent.panelLabel, "Drogue Backup")
        XCTAssertEqual(FlightStates.mainPrimaryEvent.panelLabel, "Main Primary")
        XCTAssertEqual(FlightStates.mainBackupEvent.panelLabel, "Main Backup")
        XCTAssertEqual(FlightStates.landed.panelLabel, "Landed")
    }

    /// `noSignal` is this app's fallback for an unrecognised state byte, not something
    /// the locator ever claims — so the panel says nothing, as Android's `else -> ""`
    /// does, rather than telling the user the rocket is in a state it never reported.
    func testNoSignalRendersAsNothing() {
        XCTAssertEqual(FlightStates.noSignal.panelLabel, "")
    }

    /// The failure this file exists for: no label may be the Swift case name.
    func testNoLabelIsTheCaseName() {
        for state in FlightStates.allCases {
            XCTAssertNotEqual(state.panelLabel, "\(state)",
                              "\(state) is rendering its case name, not Android's words")
        }
    }
}
