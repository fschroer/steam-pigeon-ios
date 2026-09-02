import XCTest
@testable import SteamPigeon

/// The three decision points around `ChannelMove.verdict` that each shipped a defect
/// during ADR-0011's bench validation (#20, 2026-08-30).
///
/// Every one of those defects was found by hand on a bench because the logic lived inside
/// a coroutine with a `BluetoothService` in it and nothing could reach it.
///
/// Ported from Android's `ChannelMoveOrchestrationTest.kt`. Times are `Date` here where
/// Android uses epoch milliseconds; the arithmetic is the same.
final class ChannelMoveOrchestrationTests: XCTestCase {

    // MARK: - action

    /// Reverting on anything but evidence is the defect the amendment removes.
    func testOnlyAnEvidencedLocatorStayedMovesTheReceiver() {
        XCTAssertEqual(.revert, ChannelMove.action(.locatorStayed))
        XCTAssertEqual(.succeed, ChannelMove.action(.confirmed))
        XCTAssertEqual(.stand, ChannelMove.action(.noEvidence))
        XCTAssertEqual(.stand, ChannelMove.action(.notChecked))
    }

    /// A refusal is the app failing to look. It must never authorise a move.
    func testARefusedProbeNeverMovesAnything() {
        XCTAssertEqual(.stand, ChannelMove.action(.notChecked))
    }

    // MARK: - confirmDeadline

    private let started = Date(timeIntervalSince1970: 1_000_000)
    private let window: TimeInterval = 5
    private var hard: Date { started.addingTimeInterval(2 * window) }

    func testNoReceiptLeavesTheDeadlineAlone() {
        let d = started.addingTimeInterval(window)
        XCTAssertEqual(d, ChannelMove.confirmDeadline(started: started, deadline: d,
                                                      receipt: nil, window: window,
                                                      hardDeadline: hard))
    }

    func testAReceiptRebasesTheWindowFromWhenTheCommandWentOnAir() {
        let d = started.addingTimeInterval(window)
        let receipt = started.addingTimeInterval(3)
        XCTAssertEqual(receipt.addingTimeInterval(window),
                       ChannelMove.confirmDeadline(started: started, deadline: d,
                                                   receipt: receipt, window: window,
                                                   hardDeadline: hard))
    }

    /// The hang. `ReceiverInfo` arrives every 2 s from the channel watch while the locator
    /// is silent; each one re-based by 5 s, and 2 s < 5 s meant the window never closed —
    /// the probe never ran and the locator was lost. Latching is the primary guard; this
    /// is the one that holds if the latch ever fails.
    func testRepeatedReceiptsCannotPushTheDeadlinePastTheHardCeiling() {
        var d = started.addingTimeInterval(window)
        var t = started
        for _ in 0..<50 {
            t = t.addingTimeInterval(2)          // the 2 s ReceiverInfo poll
            d = ChannelMove.confirmDeadline(started: started, deadline: d, receipt: t,
                                            window: window, hardDeadline: hard)
        }
        XCTAssertEqual(hard, d)
        XCTAssertLessThanOrEqual(d, hard, "the window must be able to close")
    }

    func testAReceiptNeverShortensADeadlineAlreadyReached() {
        let d = started.addingTimeInterval(2 * window)
        let receipt = started.addingTimeInterval(0.1)
        XCTAssertEqual(d, ChannelMove.confirmDeadline(started: started, deadline: d,
                                                      receipt: receipt, window: window,
                                                      hardDeadline: hard))
    }

    /// A receipt older than the wait belongs to a previous move.
    func testAStaleReceiptIsIgnored() {
        let d = started.addingTimeInterval(window)
        XCTAssertEqual(d, ChannelMove.confirmDeadline(started: started, deadline: d,
                                                      receipt: started.addingTimeInterval(-0.001),
                                                      window: window, hardDeadline: hard))
    }

    // MARK: - relinked

    private let asked = Date(timeIntervalSince1970: 500_000)

    func testRelinkNeedsAFrameAdmittedAfterTheRevertWasAskedFor() {
        XCTAssertTrue(ChannelMove.relinked(receiverChannel: 12, locatorChannel: 12,
                                           oldChannel: 12,
                                           lastFrame: asked.addingTimeInterval(0.001),
                                           askedAt: asked))
    }

    /// The stale-reading bug. Both channel readings are updated only by a relayed
    /// `PreLaunchData`, so after a move whose confirmation never arrived they were both
    /// still reading the old channel — and the old test passed on its first 100 ms poll
    /// having verified nothing.
    func testMatchingChannelsAloneAreNotARelink() {
        XCTAssertFalse(ChannelMove.relinked(receiverChannel: 12, locatorChannel: 12,
                                            oldChannel: 12, lastFrame: asked, askedAt: asked))
        XCTAssertFalse(ChannelMove.relinked(receiverChannel: 12, locatorChannel: 12,
                                            oldChannel: 12,
                                            lastFrame: asked.addingTimeInterval(-5),
                                            askedAt: asked))
        XCTAssertFalse(ChannelMove.relinked(receiverChannel: 12, locatorChannel: 12,
                                            oldChannel: 12, lastFrame: nil, askedAt: asked))
    }

    func testAFreshFrameOnTheWrongChannelIsNotARelink() {
        XCTAssertFalse(ChannelMove.relinked(receiverChannel: 60, locatorChannel: 12,
                                            oldChannel: 12,
                                            lastFrame: asked.addingTimeInterval(0.001),
                                            askedAt: asked))
        XCTAssertFalse(ChannelMove.relinked(receiverChannel: 12, locatorChannel: 60,
                                            oldChannel: 12,
                                            lastFrame: asked.addingTimeInterval(0.001),
                                            askedAt: asked))
    }

    // MARK: - message

    /// Nothing moved: the forward never transmitted, so the receiver never left. A much
    /// smaller problem than a stranded locator, and it must not be described as one.
    func testNoEvidenceWithTheReceiverStillOnTheOldChannelReadsAsNothingMoved() {
        XCTAssertEqual(.nothingMoved,
                       ChannelMove.message(verdict: .noEvidence, attemptedChannel: 60,
                                           receiverChannel: 34))
    }

    func testNoEvidenceWithTheReceiverOnTheNewChannelIsUnresolved() {
        XCTAssertEqual(.unresolved,
                       ChannelMove.message(verdict: .noEvidence, attemptedChannel: 60,
                                           receiverChannel: 60))
    }

    func testARefusalSaysItCouldNotCheckWhateverTheChannelsRead() {
        XCTAssertEqual(.notChecked,
                       ChannelMove.message(verdict: .notChecked, attemptedChannel: 60,
                                           receiverChannel: 34))
        XCTAssertEqual(.notChecked,
                       ChannelMove.message(verdict: .notChecked, attemptedChannel: 60,
                                           receiverChannel: 60))
    }

    func testAnEvidencedRevertSaysTheLocatorWasLeftOnItsPreviousChannel() {
        XCTAssertEqual(.leftOnPrevious,
                       ChannelMove.message(verdict: .locatorStayed, attemptedChannel: 60,
                                           receiverChannel: 34))
    }

    /// A failure with no probe recorded at all — a send failure, say.
    func testANilVerdictFallsBackToThePreviousChannelWording() {
        XCTAssertEqual(.leftOnPrevious,
                       ChannelMove.message(verdict: nil, attemptedChannel: 60,
                                           receiverChannel: 34))
    }

    /// The rule the three message defects all broke: **no sentence may claim the receiver
    /// is somewhere the app has not read.** Every message that names a channel must name
    /// the one actually reported, so the only verdict allowed to differ between "aimed at
    /// 60, sitting on 34" and "aimed at 60, sitting on 60" is the one whose whole job is
    /// telling those apart.
    func testOnlyNoEvidenceChangesItsWordingWithWhereTheReceiverActuallyIs() {
        for v: ChannelMove.Verdict in [.confirmed, .locatorStayed, .notChecked] {
            XCTAssertEqual(ChannelMove.message(verdict: v, attemptedChannel: 60, receiverChannel: 34),
                           ChannelMove.message(verdict: v, attemptedChannel: 60, receiverChannel: 60),
                           "\(v) must not depend on the receiver's channel")
        }
        XCTAssertNotEqual(ChannelMove.message(verdict: .noEvidence, attemptedChannel: 60, receiverChannel: 34),
                          ChannelMove.message(verdict: .noEvidence, attemptedChannel: 60, receiverChannel: 60))
    }
}
