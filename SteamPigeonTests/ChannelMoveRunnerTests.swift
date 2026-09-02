import XCTest
@testable import SteamPigeon

/// The **sequence** an unconfirmed channel move is resolved by — how many times it looks,
/// what it is allowed to move, and in what order.
///
/// Every defect this suite pins was found by hand on a bench during ADR-0011's validation
/// (#20), because the sequence lived inside a coroutine holding a `BluetoothService` on
/// Android — and inside `LinkViewModel` here. The decisions it calls are pinned separately
/// in `ChannelMoveTests` / `ChannelMoveOrchestrationTests`.
///
/// Ported from Android's `ChannelMoveRunnerTest.kt`, case for case and log for log.
final class ChannelMoveRunnerTests: XCTestCase {

    private let NEW = 60
    private let OLD = 34
    private let retry: TimeInterval = 6

    /// Scripted probe results, and a log of everything the runner did.
    ///
    /// A class rather than a struct because the runner holds it as an existential and the
    /// test reads what it recorded afterwards.
    private final class FakeOps: ChannelMoveRunner.Ops {
        private var queue: [ChannelMoveRunner.ProbeRun?]
        private(set) var log: [String] = []
        private(set) var verdicts: [ChannelMove.Verdict] = []
        private(set) var probeCount = 0
        private(set) var clock = Date(timeIntervalSince1970: 1)

        let relinks: Bool
        let resends: Bool
        let confirms: Bool
        let busy: Bool

        init(_ probes: ChannelMoveRunner.ProbeRun?...,
             relinks: Bool = true, resends: Bool = true,
             confirms: Bool = false, busy: Bool = false) {
            queue = probes
            self.relinks = relinks
            self.resends = resends
            self.confirms = confirms
            self.busy = busy
        }

        func probeInProgress() async -> Bool { busy }

        func runProbe(newChannel: Int, oldChannel: Int) async -> ChannelMoveRunner.ProbeRun? {
            probeCount += 1
            log.append("probe(\(newChannel),\(oldChannel))")
            // Running dry means the script was too short for the sequence under test.
            guard !queue.isEmpty else {
                XCTFail("unscripted probe #\(probeCount)")
                return nil
            }
            return queue.removeFirst()
        }

        func pause(_ interval: TimeInterval) async {
            log.append("pause(\(interval))")
            clock = clock.addingTimeInterval(interval)
        }

        func now() async -> Date { clock }

        func pointReceiverAt(_ channel: Int) async { log.append("point(\(channel))") }

        func awaitRelink(oldChannel: Int, since: Date) async -> Bool {
            log.append("relink(\(oldChannel),since=\(since.timeIntervalSince1970))")
            return relinks
        }

        func resendLocatorConfig() async -> Bool { log.append("resend"); return resends }
        func awaitConfirmation() async -> Bool { log.append("confirm"); return confirms }
        func onVerdict(_ verdict: ChannelMove.Verdict) async { verdicts.append(verdict) }
    }

    private func done(_ v: ChannelMove.Verdict) -> ChannelMoveRunner.ProbeRun {
        .init(completed: true, verdict: v)
    }
    private func refused() -> ChannelMoveRunner.ProbeRun {
        .init(completed: false, verdict: .noEvidence)
    }

    private func run(_ ops: FakeOps) async -> Bool {
        await ChannelMoveRunner(ops: ops, refusedRetry: retry)
            .resolve(newChannel: NEW, oldChannel: OLD)
    }

    /// The clock the fake starts on, as it appears in a `relink` log line.
    private let t0 = Date(timeIntervalSince1970: 1).timeIntervalSince1970

    // MARK: - Happy paths

    func testAConfirmedProbeSucceedsAndMovesNothing() async {
        let ops = FakeOps(done(.confirmed))
        let ok = await run(ops)
        XCTAssertTrue(ok)
        XCTAssertEqual(["probe(\(NEW),\(OLD))"], ops.log)
    }

    func testAnEvidencedStayRevertsRetriesAndSucceeds() async {
        let ops = FakeOps(done(.locatorStayed), confirms: true)
        let ok = await run(ops)
        XCTAssertTrue(ok)
        XCTAssertEqual(["probe(\(NEW),\(OLD))", "point(\(OLD))",
                        "relink(\(OLD),since=\(t0))", "resend", "confirm"], ops.log)
    }

    // MARK: - Silence is asked twice

    /// ADR-0029: zero frames proves nothing. One 1.4 s dwell can miss a 1 Hz burst.
    func testNoEvidenceIsProbedASecondTimeBeforeItIsAccepted() async {
        let ops = FakeOps(done(.noEvidence), done(.noEvidence))
        let ok = await run(ops)
        XCTAssertFalse(ok)
        XCTAssertEqual(2, ops.probeCount)
        XCTAssertEqual([.noEvidence], ops.verdicts)
    }

    func testASecondLookCanStillFindTheLocator() async {
        let ops = FakeOps(done(.noEvidence), done(.confirmed))
        let ok = await run(ops)
        XCTAssertTrue(ok)
        XCTAssertEqual(2, ops.probeCount)
    }

    func testNoEvidenceNeverMovesTheReceiver() async {
        let ops = FakeOps(done(.noEvidence), done(.noEvidence))
        let ok = await run(ops)
        XCTAssertFalse(ok)
        XCTAssertFalse(ops.log.contains { $0.hasPrefix("point") },
                       "nothing may be moved on no evidence")
    }

    // MARK: - Refusals are not silence

    /// The move's own queued `LocatorCfgChgRequest` blocks the search that would explain
    /// why it could not be delivered, until the receiver's stale-drop clears it.
    func testARefusedProbeIsReAskedAfterTheStaleDropDelay() async {
        let ops = FakeOps(refused(), done(.locatorStayed), confirms: true)
        let ok = await run(ops)
        XCTAssertTrue(ok)
        XCTAssertEqual(["probe(\(NEW),\(OLD))", "pause(\(retry))", "probe(\(NEW),\(OLD))",
                        "point(\(OLD))", "relink(\(OLD),since=\(t0 + retry))",
                        "resend", "confirm"], ops.log)
    }

    /// Twice declined is an answer about the app, not about the locator.
    func testTwoRefusalsGiveNotCheckedAndAreNotAskedAThirdTime() async {
        let ops = FakeOps(refused(), refused())
        let ok = await run(ops)
        XCTAssertFalse(ok)
        XCTAssertEqual(2, ops.probeCount)
        XCTAssertEqual([.notChecked], ops.verdicts)
        XCTAssertFalse(ops.log.contains { $0.hasPrefix("point") })
    }

    /// `.notChecked` must not inherit `.noEvidence`'s second look — that would be a third
    /// ask.
    func testNotCheckedIsNotReProbedTheWayNoEvidenceIs() async {
        let ops = FakeOps(refused(), refused())
        _ = await run(ops)
        XCTAssertEqual(2, ops.probeCount,
                       "exactly one refusal retry, no NoEvidence re-probe")
    }

    func testAProbeThatNeverTerminatesIsNotCheckedNotSilence() async {
        let ops = FakeOps(nil)
        let ok = await run(ops)
        XCTAssertFalse(ok)
        XCTAssertEqual([.notChecked], ops.verdicts)
    }

    func testASearchAlreadyRunningIsNotAnAnswerToThisQuestion() async {
        let ops = FakeOps(busy: true)
        let ok = await run(ops)
        XCTAssertFalse(ok)
        XCTAssertEqual(0, ops.probeCount)
        XCTAssertEqual([.notChecked], ops.verdicts)
    }

    // MARK: - The retry is not exempt

    /// The ~1-in-8 residual split. The retried `LocatorCfgChgRequest` is itself a single
    /// unacknowledged frame on the channel being left, and the receiver follows it
    /// regardless — so losing it reproduces the split one layer down. The invariant:
    /// **a failed move never ends with the receiver on a channel the probe did not
    /// confirm.**
    func testALostRetryIsLookedAtAgainAndEndsTogetherRatherThanSplit() async {
        let ops = FakeOps(done(.locatorStayed), done(.locatorStayed), confirms: false)
        let ok = await run(ops)
        XCTAssertFalse(ok)
        XCTAssertEqual(["probe(\(NEW),\(OLD))", "point(\(OLD))",
                        "relink(\(OLD),since=\(t0))", "resend", "confirm",
                        "probe(\(NEW),\(OLD))", "point(\(OLD))"], ops.log)
        XCTAssertEqual(2, ops.log.filter { $0 == "point(\(OLD))" }.count,
                       "the receiver is put back where the locator is")
    }

    func testARetryWhoseConfirmationWasMerelyLateStillSucceeds() async {
        let ops = FakeOps(done(.locatorStayed), done(.confirmed), confirms: false)
        let ok = await run(ops)
        XCTAssertTrue(ok)
        XCTAssertEqual(1, ops.log.filter { $0 == "point(\(OLD))" }.count,
                       "no revert after a confirmed second look")
    }

    /// Nothing established by the second look means nothing further is moved.
    func testASecondLookThatHearsNothingDoesNotMoveTheReceiverAgain() async {
        let ops = FakeOps(done(.locatorStayed), done(.noEvidence), confirms: false)
        let ok = await run(ops)
        XCTAssertFalse(ok)
        XCTAssertEqual(1, ops.log.filter { $0 == "point(\(OLD))" }.count)
    }

    /// Bounded: one retry, ever.
    func testTheLocatorConfigIsNeverReSentMoreThanOnce() async {
        let ops = FakeOps(done(.locatorStayed), done(.locatorStayed), confirms: false)
        _ = await run(ops)
        XCTAssertEqual(1, ops.log.filter { $0 == "resend" }.count)
    }

    // MARK: - Revert bail-outs

    func testALinkThatDoesNotComeBackStopsBeforeTheRetry() async {
        let ops = FakeOps(done(.locatorStayed), relinks: false)
        let ok = await run(ops)
        XCTAssertFalse(ok)
        XCTAssertFalse(ops.log.contains("resend"), "no retry without a link")
        XCTAssertEqual(1, ops.probeCount)
    }

    func testAFailedReSendStopsBeforeWaitingForAConfirmation() async {
        let ops = FakeOps(done(.locatorStayed), resends: false)
        let ok = await run(ops)
        XCTAssertFalse(ok)
        XCTAssertFalse(ops.log.contains("confirm"))
        XCTAssertEqual(1, ops.probeCount)
    }

    /// The relink wait must be told when we asked, so it can require a newer frame.
    func testTheRelinkDeadlineIsTakenBeforeTheReceiverIsPointed() async {
        let ops = FakeOps(done(.locatorStayed), confirms: true)
        _ = await run(ops)
        let point = ops.log.firstIndex(of: "point(\(OLD))")
        let relink = ops.log.firstIndex { $0.hasPrefix("relink") }
        XCTAssertNotNil(point); XCTAssertNotNil(relink)
        XCTAssertLessThan(point!, relink!, "point before relink")
        XCTAssertTrue(ops.log[relink!].contains("since=\(t0)"),
                      "relink carries the pre-point timestamp")
    }
}
