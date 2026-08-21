import XCTest
@testable import SteamPigeon

/// The conflicting-locator banner (ADR-0006).
///
/// Two rules make it usable rather than merely present, and both were learned the hard
/// way on Android: it must survive interleaved broadcasts, and Dismiss must actually
/// dismiss. Neither is visible from the feature description.
@MainActor
final class ConflictBannerTests: XCTestCase {

    /// With two locators on one channel the broadcasts INTERLEAVE. Clearing the banner
    /// whenever our own locator is heard made it flash on and off at the broadcast
    /// rate — visible, but gone again before Connect could be pressed. It is held for
    /// eight seconds after the conflicting locator last spoke.
    func testTheHoldOutlastsOneBroadcastPeriod() {
        XCTAssertGreaterThan(LinkViewModel.conflictHoldForTesting, 1.0,
                             "must outlast the 1 Hz broadcast that interleaves with it")
        XCTAssertEqual(8, LinkViewModel.conflictHoldForTesting)
    }

    /// The other half: the conflicting locator keeps broadcasting at 1 Hz, so simply
    /// clearing the id put the banner straight back on the next packet and Dismiss did
    /// nothing at all. The id is remembered instead.
    func testDismissIsRememberedRatherThanJustCleared() {
        let m = LinkViewModel()
        m.noteConflictForTesting(0xDEADBEEF)
        XCTAssertEqual(0xDEADBEEF, m.conflictLocatorId)

        m.dismissConflict()
        XCTAssertNil(m.conflictLocatorId)

        // The next broadcast from the same locator must NOT bring it back.
        m.noteConflictForTesting(0xDEADBEEF)
        XCTAssertNil(m.conflictLocatorId, "Dismiss did nothing")
    }

    /// A different locator is a different conflict, and is still worth showing.
    func testDismissingOneLocatorDoesNotSilenceAnother() {
        let m = LinkViewModel()
        m.noteConflictForTesting(0x1111)
        m.dismissConflict()
        m.noteConflictForTesting(0x2222)
        XCTAssertEqual(0x2222, m.conflictLocatorId)
    }

    /// Re-entering Receiver Settings is the user asking to see conflicts again.
    func testReenteringTheScreenBringsDismissedConflictsBack() {
        let m = LinkViewModel()
        m.noteConflictForTesting(0xABCD)
        m.dismissConflict()
        m.resetConflictDismissals()
        m.noteConflictForTesting(0xABCD)
        XCTAssertEqual(0xABCD, m.conflictLocatorId)
    }

    /// Hearing from the CONFLICTING locator clears its own banner — it is no longer a
    /// conflict once it is the one we are connected to.
    func testAcceptingTheConflictingLocatorClearsItsBanner() {
        let m = LinkViewModel()
        m.noteConflictForTesting(0x1234)
        m.clearConflictIfStaleForTesting(acceptedId: 0x1234, now: Date())
        XCTAssertNil(m.conflictLocatorId)
    }

    /// But hearing from OUR locator does not, until the other has been quiet for the
    /// hold. This is the interleaving case.
    func testHearingOurOwnLocatorDoesNotClearAnotherLocatorsBanner() {
        let m = LinkViewModel()
        m.noteConflictForTesting(0x1234)
        m.clearConflictIfStaleForTesting(acceptedId: 0x9999, now: Date())
        XCTAssertEqual(0x1234, m.conflictLocatorId, "flashed off between interleaved packets")
    }

    func testTheBannerExpiresOnceTheOtherLocatorGoesQuiet() {
        let m = LinkViewModel()
        m.noteConflictForTesting(0x1234)
        let later = Date().addingTimeInterval(LinkViewModel.conflictHoldForTesting + 1)
        m.clearConflictIfStaleForTesting(acceptedId: 0x9999, now: later)
        XCTAssertNil(m.conflictLocatorId)
    }

    /// Connect does nothing without a frame from THAT locator to verify against.
    /// Armed locators raise conflicts too, and an armed stranger carries no identity to
    /// check a password against — checking one against another locator's tag is
    /// meaningless at best and a false accept at worst.
    func testConnectDoesNothingWithoutAFrameFromThatLocator() {
        let m = LinkViewModel()
        m.noteConflictForTesting(0x5555)
        m.requestConnectToConflict()          // no prelaunch frame recorded
        XCTAssertNil(m.connectedLocatorId)
        XCTAssertNil(m.challenge)
    }
}
