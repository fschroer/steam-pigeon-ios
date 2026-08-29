import XCTest
@testable import SteamPigeon

/// The ADR-0011 channel-change recognition cycle, ported to iOS 2026-08-28 after a
/// defect reported from the phone.
///
/// **The report.** After a whole-band search, tapping Connect on a *different* locator's
/// hit: every row then read "Connect", the Receiver channel field followed the new
/// channel while the Locator channel did not, and the main screen showed no locator at
/// all — "as if the receiver was set to another channel entirely".
///
/// The receiver was on the right channel throughout. The app was refusing to display what
/// was on it, because `pointReceiverAtChannel` moved the receiver without releasing the
/// connection: the old holder was off-channel and silent, and the new locator was refused
/// as `conflict` for `connectionHold`, or — if its password was not held — for ever,
/// since `ChallengePolicy`'s passive trigger only prompts while nothing is connected.
///
/// **Android has never had this**, because its `pointReceiverAtChannel` calls
/// `beginChannelChangeRecognition` first. This is a port of that, and these tests pin
/// each symptom in the report.
@MainActor
final class ChannelChangeRecognitionTests: XCTestCase {

    private let ours: UInt32 = 0x1111_1111
    private let theirs: UInt32 = 0x2222_2222

    /// A defaults suite of this test run's own, wiped between cases.
    ///
    /// **Not `UserDefaults.standard`.** Half of these tests need a locator the app is
    /// *not* authorized for, and a password accepted by one case is persisted — on the
    /// simulator that outlives the whole suite, so the next run starts with the locator
    /// already authorized and the case silently stops testing what it says it does. It
    /// fails open: the polluted path is the one where everything appears to work.
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suite = "ChannelChangeRecognitionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
        super.tearDown()
    }

    /// Put the model in the reported starting state: connected to `ours`, receiver on
    /// channel 34.
    private func connectedModel() -> LinkViewModel {
        let m = LinkViewModel(defaults: defaults)
        m.ingestForTesting(prelaunchFrame(locatorId: ours, key: 0, deviceName: "Twist 0",
                                          channel: 34))
        XCTAssertEqual(ours, m.connectedLocatorId, "precondition: connected to the first locator")
        return m
    }

    // MARK: - The symptom

    /// The heart of it: the slot is released the moment the change goes out, so the
    /// first locator heard on the new channel can claim it rather than waiting out
    /// `connectionHold` — or waiting for ever.
    func testPointingTheReceiverReleasesTheConnection() {
        let m = connectedModel()
        m.pointReceiverAtChannel(57)
        XCTAssertNil(m.connectedLocatorId,
                     "the point of the change is to go somewhere else")
        XCTAssertTrue(m.isAwaitingChannelRecognition)
    }

    /// An **authorized** locator on the new channel connects on its first broadcast.
    /// Before the fix this came back as `conflict` and the screen stayed empty for the
    /// full 15 s hold.
    func testAnOpenLocatorOnTheNewChannelConnectsImmediately() {
        let m = connectedModel()
        m.pointReceiverAtChannel(57)
        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: 0, deviceName: "Prometheus",
                                          channel: 57))
        XCTAssertEqual(theirs, m.connectedLocatorId)
        XCTAssertFalse(m.isAwaitingChannelRecognition, "resolved — nothing left to revert")
    }

    /// An **unauthorized** locator on the new channel raises the password prompt. This is
    /// the case that never recovered: the passive trigger refuses to prompt while
    /// anything is connected, so with the old holder still in the slot the user got no
    /// dialog, no locator, and no way to reach either.
    func testAnUnknownLocatorOnTheNewChannelIsChallenged() throws {
        let m = connectedModel()
        m.pointReceiverAtChannel(57)
        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: 0xABCD_1234,
                                          deviceName: "Prometheus", channel: 57))

        let challenge = try XCTUnwrap(m.challenge, "a deliberate move onto a stranger must ask")
        XCTAssertEqual(theirs, challenge.locatorId)
        XCTAssertEqual("Prometheus", challenge.deviceName)
        XCTAssertEqual(34, challenge.previousChannel, "cancel has to know where to go back to")
    }

    /// The user went to this channel on purpose, so "somebody else is on your channel"
    /// is not the right thing to say about the channel they just chose.
    func testAChannelChangeChallengeDoesNotAlsoRaiseTheConflictBanner() {
        let m = connectedModel()
        m.pointReceiverAtChannel(57)
        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: 0xABCD_1234,
                                          deviceName: "Prometheus", channel: 57))
        XCTAssertNil(m.conflictLocatorId)
    }

    /// A locator declined once before must still be offered after a deliberate move to
    /// its channel — `.passive` stays quiet for a declined locator, `.channelChange`
    /// does not.
    func testADeclinedLocatorIsStillChallengedAfterADeliberateMove() {
        let m = LinkViewModel(defaults: defaults)
        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: 0xABCD_1234,
                                          deviceName: "Prometheus", channel: 34))
        XCTAssertNotNil(m.challenge, "precondition: the passive prompt was raised")
        m.declineChallenge()
        XCTAssertNil(m.challenge)

        m.pointReceiverAtChannel(57)
        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: 0xABCD_1234,
                                          deviceName: "Prometheus", channel: 57))
        XCTAssertNotNil(m.challenge, "the user has just asked to go here — ask again")
    }

    // MARK: - Cancelling

    /// Cancel **reverts**, because it is the only way back: the locator the user left is
    /// off-channel and the one they found is not displayable, so a dialog that merely
    /// dismissed would leave a blank screen and no explanation.
    func testCancellingAChannelChangeChallengeSendsTheReceiverBack() {
        let m = connectedModel()
        m.pointReceiverAtChannel(57)
        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: 0xABCD_1234,
                                          deviceName: "Prometheus", channel: 57))
        XCTAssertNotNil(m.challenge)

        m.declineChallenge()
        XCTAssertNil(m.challenge)
        XCTAssertFalse(m.isAwaitingChannelRecognition)
        // The revert is a receiver config change like any other, so it reports through
        // the same state the Update button reads.
        XCTAssertNotEqual(ConfigMessageState.idle, m.receiverConfigMessageState,
                          "a revert must actually be sent, not merely intended")
    }

    /// A passive prompt has nothing to undo, so it is remembered as declined instead —
    /// at 1 Hz, re-asking would be unusable.
    func testCancellingAPassiveChallengeDeclinesRatherThanReverting() {
        let m = LinkViewModel(defaults: defaults)
        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: 0xABCD_1234,
                                          deviceName: "Prometheus", channel: 34))
        XCTAssertNotNil(m.challenge)
        m.declineChallenge()

        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: 0xABCD_1234,
                                          deviceName: "Prometheus", channel: 34))
        XCTAssertNil(m.challenge, "a declined locator must not re-prompt every broadcast")
    }

    // MARK: - Accepting

    /// A correct password takes the connection **now**, as Android's `submitPassword`
    /// does. Leaving it to the next broadcast works only when the slot is free; with a
    /// previous holder still inside `connectionHold` the next frame comes back as
    /// `conflict`, so a correct password bought 15 s of a blank screen.
    func testACorrectPasswordConnectsWithoutWaitingForAnotherBroadcast() {
        let m = connectedModel()
        m.pointReceiverAtChannel(57)
        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: LocatorAuth.deriveKey("hunter2"),
                                          deviceName: "Prometheus", channel: 57))
        XCTAssertNotNil(m.challenge)

        XCTAssertTrue(m.submitPassword("hunter2"))
        XCTAssertEqual(theirs, m.connectedLocatorId)
        XCTAssertNil(m.challenge)
    }

    /// A wrong password leaves the dialog open to retry and connects nothing.
    func testAWrongPasswordConnectsNothing() {
        let m = connectedModel()
        m.pointReceiverAtChannel(57)
        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: LocatorAuth.deriveKey("hunter2"),
                                          deviceName: "Prometheus", channel: 57))
        XCTAssertFalse(m.submitPassword("wrong"))
        XCTAssertNil(m.connectedLocatorId)
        XCTAssertEqual(true, m.challenge?.rejected)
    }

    // MARK: - Guards

    /// Pointing at the channel we are already on must NOT release the connection —
    /// that would drop a live locator for a button press that changes nothing.
    func testPointingAtTheCurrentChannelChangesNothing() {
        let m = connectedModel()
        m.pointReceiverAtChannel(34)
        XCTAssertEqual(ours, m.connectedLocatorId)
        XCTAssertFalse(m.isAwaitingChannelRecognition)
    }

    /// A locator channel move is ADR-0011's *other* cycle — the locator carries the whole
    /// system across and the receiver follows — so it must not release the connection.
    func testMovingTheLocatorDoesNotReleaseTheConnection() {
        let m = connectedModel()
        m.moveLocatorToChannel(57)
        XCTAssertEqual(ours, m.connectedLocatorId)
        XCTAssertFalse(m.isAwaitingChannelRecognition)
    }

    /// While the move is unresolved, the channel we came from is worth searching: it is
    /// where the locator was last actually heard.
    func testTheChannelWeCameFromBecomesASearchCandidate() {
        let m = connectedModel()
        m.pointReceiverAtChannel(57)
        XCTAssertTrue(m.searchCandidates().contains(34))
    }

    /// Reported 2026-08-29: the Locator channel field kept showing the PREVIOUS
    /// locator's channel after the receiver had been pointed elsewhere — two real
    /// locators, two real channels, and a field describing the one the app had let go
    /// of. It corrects itself only when the new locator is admitted, so a locator that
    /// is never admitted leaves it wrong indefinitely.
    func testReleasingTheConnectionDropsThePreviousLocatorsConfig() {
        let m = connectedModel()
        m.ingestForTesting(prelaunchFrame(locatorId: ours, key: 0, deviceName: "Twist 0",
                                          channel: 34))
        XCTAssertEqual("Twist 0", m.remoteLocatorConfig.deviceName,
                       "precondition: the config describes the connected locator")

        m.pointReceiverAtChannel(57)
        XCTAssertEqual(LocatorConfig(), m.remoteLocatorConfig,
                       "a released locator's configuration must not be left on screen")
    }

    // MARK: - A password changed on the locator

    /// Reported from the phone 2026-08-29 and reproduced before fixing: once the app is
    /// connected, a locator whose password is then changed on the device becomes
    /// permanently unreachable.
    ///
    /// Its frames stop authenticating, so nothing is admitted; `connectedLocatorId` goes
    /// on naming it, because nothing released a connection on an auth failure; and the
    /// `.passive` trigger refuses to prompt while anything is connected. The only things
    /// on screen were a conflict banner calling the connected locator "another locator"
    /// and a status panel reading "No Locator" over the last good RSSI. There was no way
    /// out short of dropping the BLE link.
    func testAChangedPasswordReleasesTheConnectionAndAsksAgain() throws {
        let m = LinkViewModel(defaults: defaults)
        m.ingestForTesting(prelaunchFrame(locatorId: ours, key: LocatorAuth.deriveKey("old"),
                                          deviceName: "Twist 0", channel: 34))
        XCTAssertNotNil(m.challenge, "precondition: the passive prompt was raised")
        XCTAssertTrue(m.submitPassword("old"))
        XCTAssertEqual(ours, m.connectedLocatorId, "precondition: connected")

        // The password is changed ON THE LOCATOR; its frames now carry a different tag.
        m.ingestForTesting(prelaunchFrame(locatorId: ours, key: LocatorAuth.deriveKey("new"),
                                          deviceName: "Twist 0", channel: 34))

        let challenge = try XCTUnwrap(m.challenge, "the app must ask again, not go deaf")
        XCTAssertEqual(ours, challenge.locatorId)
        XCTAssertNil(challenge.previousChannel, "nothing to revert — no channel moved")
        XCTAssertNil(m.connectedLocatorId, "the connection was a stale belief")
        XCTAssertNil(m.conflictLocatorId,
                     "the holder is not 'another locator' — that banner named itself")
    }

    /// And the way out works: the new password reconnects.
    func testTheNewPasswordReconnects() {
        let m = LinkViewModel(defaults: defaults)
        m.ingestForTesting(prelaunchFrame(locatorId: ours, key: LocatorAuth.deriveKey("old"),
                                          deviceName: "Twist 0", channel: 34))
        XCTAssertTrue(m.submitPassword("old"))
        m.ingestForTesting(prelaunchFrame(locatorId: ours, key: LocatorAuth.deriveKey("new"),
                                          deviceName: "Twist 0", channel: 34))
        XCTAssertTrue(m.submitPassword("new"))
        XCTAssertEqual(ours, m.connectedLocatorId)
        XCTAssertNil(m.challenge)
    }

    /// A locator we are NOT connected to must still be left alone — an armed stranger on
    /// the channel does not get to knock out the locator we are showing.
    func testAStrangerStillDoesNotDisturbAStandingConnection() {
        let m = LinkViewModel(defaults: defaults)
        m.ingestForTesting(prelaunchFrame(locatorId: ours, key: 0,
                                          deviceName: "Twist 0", channel: 34))
        XCTAssertEqual(ours, m.connectedLocatorId, "precondition: an open locator connects")

        m.ingestForTesting(prelaunchFrame(locatorId: theirs, key: LocatorAuth.deriveKey("x"),
                                          deviceName: "Stranger", channel: 34))
        XCTAssertEqual(ours, m.connectedLocatorId, "the stranger must not release our link")
        XCTAssertEqual(theirs, m.conflictLocatorId, "it is genuinely another locator")
    }

    // MARK: - A change already in flight

    /// Reported from the phone 2026-08-29: the Connect buttons stayed live while a
    /// change was under way. The send is refused by the guard, so the second tap did
    /// nothing at all — the "a control that silently did nothing" failure this screen
    /// exists to avoid. The view disables them; this pins the guard they rely on.
    func testASecondPointIsRefusedWhileOneIsInFlight() {
        let m = connectedModel()
        XCTAssertTrue(m.pointReceiverAtChannel(57))
        XCTAssertFalse(m.pointReceiverAtChannel(12),
                       "a second change cannot go out while the first is unresolved")
    }

    /// And the caller must be able to tell, because staging a channel that was never
    /// sent put a number the app had not visited into the Receiver channel field — with
    /// an enabled Update button offering to apply it.
    func testPointingReportsWhetherItActuallyWentOut() {
        let m = connectedModel()
        XCTAssertFalse(m.pointReceiverAtChannel(34), "already there")
        XCTAssertTrue(m.pointReceiverAtChannel(57))
    }

    // MARK: -

    /// A pre-launch frame carrying `deviceName` and the receiver's `channel`,
    /// authenticated under `key`.
    private func prelaunchFrame(locatorId: UInt32, key: UInt32,
                                deviceName: String, channel: UInt8) -> [UInt8] {
        var f = [UInt8](repeating: 0,
                        count: WireProtocol.headerSize + WireProtocol.prelaunchMessagePayloadSize)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.preLaunchData.rawValue
        // 13 bytes follow the name inside the authenticated struct: battery (2), nose
        // axis, armed, pad alert, then `locator_id` and `auth_tag` (4 each).
        let nameOffset = WireProtocol.prelaunchBaseStructSize - 13 - WireProtocol.deviceNameLength
        for (i, b) in Array(deviceName.utf8).prefix(WireProtocol.deviceNameLength).enumerated() {
            f[nameOffset + i] = b
        }
        writeU32(&f, at: WireProtocol.prelaunchBaseStructSize - 8, locatorId)
        seal(&f, at: WireProtocol.prelaunchBaseStructSize - 4, key: key,
             baseSize: WireProtocol.prelaunchBaseStructSize)
        // The receiver appends its own channel immediately after the authenticated
        // struct, so it sits OUTSIDE the auth tag and is written after sealing.
        f[WireProtocol.prelaunchBaseStructSize] = channel
        return f
    }

    private func writeU32(_ f: inout [UInt8], at o: Int, _ v: UInt32) {
        for i in 0..<4 { f[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }

    private func seal(_ f: inout [UInt8], at o: Int, key: UInt32, baseSize: Int) {
        let tag = LocatorAuth.expectedAuthTag(frame: f, passwordKey: key, baseSize: baseSize)!
        writeU32(&f, at: o, tag)
    }
}
