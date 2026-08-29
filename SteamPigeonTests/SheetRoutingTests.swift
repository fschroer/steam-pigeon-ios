import XCTest
@testable import SteamPigeon

/// One sheet per screen — the invariant behind the iOS 16 crash.
///
/// Tested rather than eyeballed because the failure is invisible in the place it is
/// introduced: adding a second `.sheet` looks fine, compiles, and works on newer iOS
/// (an iOS 26 simulator will not reproduce it), then throws
/// `NSInvalidArgumentException … is already being presented` on the 16.7 phone the
/// app is actually flown with.
final class SheetRoutingTests: XCTestCase {

    // MARK: - Identity is stable, so content swaps instead of re-presenting

    /// The whole point. If these ids differed, picking a menu item would dismiss one
    /// sheet and present another — the crashing sequence moved inside the modifier
    /// rather than removed.
    func testMapMenuAndDestinationShareOneIdentity() {
        XCTAssertEqual(MapSheet.menu.id, MapSheet.destination(.appSettings).id)
        for destination in MenuDestination.allCases {
            XCTAssertEqual(MapSheet.menu.id, MapSheet.destination(destination).id)
        }
    }

    /// Same rule on the root view: a challenge arriving over anything else must change
    /// what the sheet shows, not present a second sheet.
    func testEveryRootSheetSharesOneIdentity() {
        XCTAssertEqual(RootSheet.diagnostics.id, RootSheet.challenge(Self.challenge).id)
        XCTAssertEqual(RootSheet.diagnostics.id, RootSheet.map(.menu).id)
        for destination in MenuDestination.allCases {
            XCTAssertEqual(RootSheet.diagnostics.id, RootSheet.map(.destination(destination)).id)
        }
    }

    // MARK: - One presentation for the WHOLE app, not one per screen

    /// The gap that cost the password prompt (2026-08-29). `MapScreen` presented the
    /// menu and its destinations while `RootView` — which contains it — presented the
    /// challenge. One sheet each, and still two presentations in one chain: an ancestor
    /// cannot present while a descendant already is.
    ///
    /// Measured on the simulator with the Communication screen open: the prompt did not
    /// appear at all until that sheet was dismissed, then churned appear/disappear/appear
    /// in a single tick. It was raised exactly where it could not be shown — connecting
    /// to a locator a search just found is a menu destination.
    func testAChallengeOutranksAnOpenMenuDestination() {
        XCTAssertEqual(.challenge(Self.challenge),
                       RootSheet.active(challenge: Self.challenge,
                                        map: .destination(.communication),
                                        showDiagnostics: false))
    }

    /// Answering it returns to the screen underneath rather than closing it — the user
    /// did not ask to leave the search results that raised the prompt.
    func testAnsweringAChallengeReturnsToTheScreenUnderneath() {
        XCTAssertEqual(.map(.destination(.communication)),
                       RootSheet.active(challenge: nil,
                                        map: .destination(.communication),
                                        showDiagnostics: false))
    }

    /// A menu destination outranks diagnostics: diagnostics is a button the user pressed
    /// once, and the destination is where they are now.
    func testAMenuDestinationOutranksDiagnostics() {
        XCTAssertEqual(.map(.menu),
                       RootSheet.active(challenge: nil, map: .menu, showDiagnostics: true))
    }

    /// With nothing else open the map's sheet is what shows.
    func testTheMapSheetShowsWhenNothingOutranksIt() {
        XCTAssertEqual(.map(.menu),
                       RootSheet.active(challenge: nil, map: .menu, showDiagnostics: false))
    }

    // MARK: - Which one wins

    func testNothingWantsASheet() {
        XCTAssertNil(RootSheet.active(challenge: nil, showDiagnostics: false))
    }

    func testDiagnosticsAloneShowsDiagnostics() {
        XCTAssertEqual(.diagnostics, RootSheet.active(challenge: nil, showDiagnostics: true))
    }

    func testChallengeAloneShowsTheChallenge() {
        XCTAssertEqual(.challenge(Self.challenge),
                       RootSheet.active(challenge: Self.challenge, showDiagnostics: false))
    }

    /// The latent half of the crash: a locator can challenge at any moment, including
    /// while diagnostics is open. The challenge wins — it is the one that has to be
    /// answered, and it was not the user who asked for it.
    func testChallengeOutranksAnOpenDiagnosticsSheet() {
        XCTAssertEqual(.challenge(Self.challenge),
                       RootSheet.active(challenge: Self.challenge, showDiagnostics: true))
    }

    /// Answering the challenge returns to diagnostics rather than closing it. The user
    /// did not ask to leave that screen; a locator interrupted them.
    func testAnsweringAChallengeReturnsToDiagnostics() {
        XCTAssertEqual(.diagnostics, RootSheet.active(challenge: nil, showDiagnostics: true))
    }

    /// A rejected password keeps the SAME sheet up — `rejected` changes the value, so
    /// the prompt can show its error, but not the identity, so it is not re-presented.
    func testARejectedPasswordDoesNotRepresentTheSheet() {
        var rejected = Self.challenge
        rejected.rejected = true

        let first = RootSheet.active(challenge: Self.challenge, showDiagnostics: false)
        let second = RootSheet.active(challenge: rejected, showDiagnostics: false)

        XCTAssertNotEqual(first, second, "the prompt must see that it was rejected")
        XCTAssertEqual(first?.id, second?.id, "but must not be dismissed and re-presented")
    }

    private static let challenge = LocatorChallenge(locatorId: 0xDEADBEEF,
                                                    deviceName: "Test locator")
}
