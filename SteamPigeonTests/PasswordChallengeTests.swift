import XCTest
@testable import SteamPigeon

/// ADR-0006 Decision 6 — when the app prompts, and when it must not.
///
/// Most of these assert *silence*. A prompt that reappears every broadcast at 1 Hz is
/// as unusable as one that never appears, and a prompt that interrupts a live
/// connection is worse than either.
final class PasswordChallengeTests: XCTestCase {

    private let base = WireProtocol.prelaunchBaseStructSize

    private func prelaunchFrame(locatorId: UInt32, key: UInt32) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 147)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.preLaunchData.rawValue
        for i in 6..<110 { f[i] = UInt8(truncatingIfNeeded: i &* 3 &+ 7) }
        f[110] = UInt8(truncatingIfNeeded: locatorId)
        f[111] = UInt8(truncatingIfNeeded: locatorId >> 8)
        f[112] = UInt8(truncatingIfNeeded: locatorId >> 16)
        f[113] = UInt8(truncatingIfNeeded: locatorId >> 24)
        let tag = LocatorAuth.expectedAuthTag(frame: f, passwordKey: key, baseSize: base)!
        f[114] = UInt8(truncatingIfNeeded: tag)
        f[115] = UInt8(truncatingIfNeeded: tag >> 8)
        f[116] = UInt8(truncatingIfNeeded: tag >> 16)
        f[117] = UInt8(truncatingIfNeeded: tag >> 24)
        return f
    }

    // MARK: - When to prompt

    func testPassivePromptOnFirstContactWhileNotConnected() {
        let p = ChallengePolicy()
        XCTAssertTrue(p.shouldChallenge(locatorId: 1, hasDeviceName: true, connected: nil,
                                        challengeOpen: false, trigger: .passive))
    }

    /// A passive prompt must never interrupt a live connection — an armed stranger on
    /// the channel must not knock out the locator we are flying.
    func testNoPassivePromptWhileConnected() {
        let p = ChallengePolicy()
        XCTAssertFalse(p.shouldChallenge(locatorId: 2, hasDeviceName: true, connected: 1,
                                         challengeOpen: false, trigger: .passive))
    }

    /// The decline must stick, or the prompt returns at the broadcast rate.
    func testDeclinedLocatorIsNotAskedAgain() {
        var p = ChallengePolicy()
        p.decline(3)
        XCTAssertFalse(p.shouldChallenge(locatorId: 3, hasDeviceName: true, connected: nil,
                                         challengeOpen: false, trigger: .passive))
    }

    func testExplicitConnectClearsADecline() {
        var p = ChallengePolicy()
        p.decline(3)
        p.reconsider(3)
        XCTAssertTrue(p.shouldChallenge(locatorId: 3, hasDeviceName: true, connected: nil,
                                        challengeOpen: false, trigger: .passive))
    }

    func testOnlyOneDialogAtATime() {
        let p = ChallengePolicy()
        XCTAssertFalse(p.shouldChallenge(locatorId: 4, hasDeviceName: true, connected: nil,
                                         challengeOpen: true, trigger: .passive))
    }

    /// An unknown ARMED locator cannot be challenged: the dialog needs the device name
    /// only PreLaunchData carries. It becomes connectable when it disarms — the only
    /// state in which connecting is useful anyway.
    func testArmedStrangerCannotBeChallenged() {
        let p = ChallengePolicy()
        XCTAssertFalse(p.shouldChallenge(locatorId: 5, hasDeviceName: false, connected: nil,
                                         challengeOpen: false, trigger: .passive))
    }

    /// A deliberate channel change asks even about a previously declined locator —
    /// the user just acted on purpose, and cancelling reverts the channel.
    func testChannelChangeAsksEvenAfterADecline() {
        var p = ChallengePolicy()
        p.decline(6)
        XCTAssertTrue(p.shouldChallenge(locatorId: 6, hasDeviceName: true, connected: 99,
                                        challengeOpen: false, trigger: .channelChange))
    }

    func testChannelChangeStillNeedsADeviceName() {
        let p = ChallengePolicy()
        XCTAssertFalse(p.shouldChallenge(locatorId: 7, hasDeviceName: false, connected: nil,
                                         challengeOpen: false, trigger: .channelChange))
    }

    // MARK: - Verifying what the user typed

    func testCorrectPasswordYieldsTheKeyToStore() {
        let key = LocatorAuth.deriveKey("launch42")
        let f = prelaunchFrame(locatorId: 10, key: key)
        XCTAssertEqual(key, KnownLocatorStore.verify(password: "launch42", frame: f, baseSize: base))
    }

    func testWrongPasswordYieldsNothing() {
        let f = prelaunchFrame(locatorId: 11, key: LocatorAuth.deriveKey("right"))
        XCTAssertNil(KnownLocatorStore.verify(password: "wrong", frame: f, baseSize: base))
    }

    /// A blank password derives key 0, which is exactly how an OPEN locator
    /// authenticates — so "no password" is a legitimate answer, not an empty
    /// submission to reject.
    func testBlankPasswordAuthenticatesAnOpenLocator() {
        let f = prelaunchFrame(locatorId: 12, key: 0)
        XCTAssertEqual(0, KnownLocatorStore.verify(password: "", frame: f, baseSize: base))
    }

    func testBlankPasswordFailsAProtectedLocator() {
        let f = prelaunchFrame(locatorId: 13, key: LocatorAuth.deriveKey("secret"))
        XCTAssertNil(KnownLocatorStore.verify(password: "", frame: f, baseSize: base))
    }

    // MARK: - Persistence

    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testKeysSurviveARelaunch() {
        let suite = "test.knownLocators.\(UUID().uuidString)"
        let d = freshDefaults(suite)
        var store = KnownLocatorStore(defaults: d)
        store.remember(locatorId: 0xDEADBEEF, passwordKey: 0x12345678)

        let reloaded = KnownLocatorStore(defaults: d)
        XCTAssertEqual(0x12345678, reloaded.keysById[0xDEADBEEF])
        d.removePersistentDomain(forName: suite)
    }

    func testForgettingRemovesTheKey() {
        let suite = "test.knownLocators.\(UUID().uuidString)"
        let d = freshDefaults(suite)
        var store = KnownLocatorStore(defaults: d)
        store.remember(locatorId: 1, passwordKey: 42)
        store.forget(locatorId: 1)
        XCTAssertNil(KnownLocatorStore(defaults: d).keysById[1])
        d.removePersistentDomain(forName: suite)
    }

    /// A stored key of 0 is meaningful — it records "this locator is open" — and must
    /// round-trip rather than being mistaken for absence.
    func testAnOpenLocatorsZeroKeyRoundTrips() {
        let suite = "test.knownLocators.\(UUID().uuidString)"
        let d = freshDefaults(suite)
        var store = KnownLocatorStore(defaults: d)
        store.remember(locatorId: 77, passwordKey: 0)
        XCTAssertEqual(0, KnownLocatorStore(defaults: d).keysById[77])
        d.removePersistentDomain(forName: suite)
    }

    // MARK: - End to end with the gate

    /// The whole point: a protected locator is refused, the user supplies the
    /// password, and it is then admitted.
    func testProtectedLocatorIsAdmittedOnlyAfterTheRightPassword() {
        let key = LocatorAuth.deriveKey("launch42")
        let f = prelaunchFrame(locatorId: 20, key: key)

        var gate = LocatorGate()
        XCTAssertEqual(.unauthorized(20), gate.evaluate(frame: f, locatorId: 20, baseSize: base))

        let derived = KnownLocatorStore.verify(password: "launch42", frame: f, baseSize: base)
        gate.remember(locatorId: 20, passwordKey: try! XCTUnwrap(derived))

        XCTAssertEqual(.accepted(20), gate.evaluate(frame: f, locatorId: 20, baseSize: base))
    }
}
