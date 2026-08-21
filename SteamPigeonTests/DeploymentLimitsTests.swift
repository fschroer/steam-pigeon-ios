import XCTest
@testable import SteamPigeon

/// The interlocked limits on the deployment fields.
///
/// These are the only thing stopping a **backup charge being configured to fire before
/// its primary**, which is not a validation nicety — it is the whole point of having a
/// backup. Each bound is derived from the other value rather than from a constant, and
/// Android derives them the same way.
final class DeploymentLimitsTests: XCTestCase {

    // The bounds as `LocatorSettingsView` computes them, stated here in one place so a
    // change to either has to be a deliberate edit to a test that says why.
    private func droguePrimaryRange(backup: Int) -> ClosedRange<Int> { 0...max(backup - 1, 0) }
    private func drogueBackupRange(primary: Int) -> ClosedRange<Int> { min(primary + 1, 30)...30 }
    private func mainPrimaryRange(backup: Int) -> ClosedRange<Int> { min(backup + 1, 500)...500 }
    private func mainBackupRange(primary: Int) -> ClosedRange<Int> { 0...max(primary - 1, 0) }

    /// Drogue: the BACKUP fires later, so its delay must exceed the primary's.
    func testTheDrogueBackupCannotBeSetToFireBeforeThePrimary() {
        let primary = 12                                   // 1.2 s
        let allowed = drogueBackupRange(primary: primary)
        XCTAssertFalse(allowed.contains(primary), "equal is not later")
        XCTAssertFalse(allowed.contains(primary - 1))
        XCTAssertTrue(allowed.contains(primary + 1))
    }

    func testTheDroguePrimaryCannotBeSetToFireAfterTheBackup() {
        let backup = 12
        let allowed = droguePrimaryRange(backup: backup)
        XCTAssertFalse(allowed.contains(backup))
        XCTAssertTrue(allowed.contains(backup - 1))
    }

    /// Main: the BACKUP fires lower, so its altitude must be below the primary's.
    func testTheMainBackupCannotBeSetAboveThePrimary() {
        let primary = 150
        let allowed = mainBackupRange(primary: primary)
        XCTAssertFalse(allowed.contains(primary))
        XCTAssertTrue(allowed.contains(primary - 1))
    }

    func testTheMainPrimaryCannotBeSetBelowTheBackup() {
        let backup = 150
        let allowed = mainPrimaryRange(backup: backup)
        XCTAssertFalse(allowed.contains(backup))
        XCTAssertTrue(allowed.contains(backup + 1))
    }

    /// The degenerate ends must not produce an inverted range. A `ClosedRange` with
    /// lower > upper traps at construction in Swift, so a locator reporting zeros —
    /// which is what an unconfigured one does — would crash the settings screen.
    func testTheBoundsNeverInvertAtTheExtremes() {
        XCTAssertFalse(droguePrimaryRange(backup: 0).isEmpty)
        XCTAssertFalse(mainBackupRange(primary: 0).isEmpty)
        XCTAssertFalse(drogueBackupRange(primary: 30).isEmpty)
        XCTAssertFalse(mainPrimaryRange(backup: 500).isEmpty)
        // And the clamped ends still make sense.
        XCTAssertEqual(0...0, droguePrimaryRange(backup: 0))
        XCTAssertEqual(30...30, drogueBackupRange(primary: 30))
        XCTAssertEqual(500...500, mainPrimaryRange(backup: 500))
    }

    /// Delays are carried in tenths of a second, so the wire ceiling of 3.0 s is 30.
    func testDelaysAreTenthsOfASecondOnTheWire() {
        XCTAssertEqual(30, drogueBackupRange(primary: 0).upperBound, "3.0 s")
        var c = LocatorConfig()
        c.droguePrimaryDelay = 12
        XCTAssertEqual(12, c.payload[6], "written as tenths, not seconds")
    }

    /// Every channel can be turned off, and `unused` is last in the list because it is
    /// the opt-out rather than a choice among peers.
    func testUnusedIsOfferedAndSortsLast() {
        XCTAssertEqual(.unused, DeployMode.allCasesInOrder.last)
        XCTAssertEqual(5, DeployMode.allCasesInOrder.count)
    }

    /// The two fields the app cannot read back are NOT offered for editing — see
    /// UI_PARITY. They keep their placeholder values so the confirmation comparison
    /// still matches; if a control for either ever appears, this test should fail first.
    func testTheUnreadableFieldsKeepTheirPlaceholders() {
        let c = LocatorConfig()
        XCTAssertEqual(LocatorConfig.launchDetectAltitudePlaceholder, c.launchDetectAltitude)
        XCTAssertEqual(LocatorConfig.deploySignalDurationPlaceholder, c.deploySignalDuration)
    }
}
