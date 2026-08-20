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

    /// Same rule on the root view: a challenge arriving over diagnostics must change
    /// what the sheet shows, not present a second sheet.
    func testRootChallengeAndDiagnosticsShareOneIdentity() {
        XCTAssertEqual(RootSheet.diagnostics.id, RootSheet.challenge(Self.challenge).id)
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
