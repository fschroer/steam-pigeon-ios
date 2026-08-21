import XCTest
@testable import SteamPigeon

/// The deployment test's state machine (ADR-0027).
///
/// **The display follows the locator, never the app's own hope.** Every frame involved is
/// unacknowledged — the request that starts a test and the request that stops one — so
/// the countdown arriving is the only evidence a charge is live, and the countdown going
/// quiet is the only evidence a test has ended.
///
/// Android learned this the expensive way: pressing cancel cleared `active` immediately,
/// which gated the countdown handler and made the app deaf to the countdown still
/// running. The button read "start" while the locator counted down and fired, and nothing
/// on screen disagreed. Every case below is that bug, approached from a different side.
@MainActor
final class DeploymentTestTests: XCTestCase {

    // MARK: - Wire contract

    /// **0 is not "nothing selected", it is CANCEL.** The stop control and the exit path
    /// both send a channel byte rather than a different message, so this value is load
    /// bearing on the locator side.
    func testNoneIsTheCancelValue() {
        XCTAssertEqual(0, DeploymentTestOption.none.rawValue)
        XCTAssertEqual([1, 2, 3, 4],
                       DeploymentTestOption.allCases.filter { $0 != .none }.map(\.rawValue))
    }

    /// Android renders the enum's case names, and the manual prints one string for both
    /// platforms.
    func testLabelsAreAndroidsCaseNames() {
        XCTAssertEqual("None", DeploymentTestOption.none.label)
        XCTAssertEqual("Channel1", DeploymentTestOption.channel1.label)
        XCTAssertEqual("Channel4", DeploymentTestOption.channel4.label)
    }

    func testCountdownParsesTheSecondsByte() {
        var frame = [UInt8](repeating: 0, count: WireProtocol.headerSize + 1)
        frame[0] = WireProtocol.systemId
        frame[1] = MsgType.deploymentTest.rawValue
        frame[WireProtocol.headerSize] = 7
        XCTAssertEqual(7, DeploymentTestCountdown.parse(frame)?.secondsRemaining)

        // A short frame is refused rather than read as a zero countdown — "0 seconds
        // left" and "no idea" must not be the same value on this screen.
        XCTAssertNil(DeploymentTestCountdown.parse(Array(frame.prefix(WireProtocol.headerSize))))
    }

    // MARK: - The display follows the locator

    /// A cancel is a REQUEST. It marks itself pending and changes nothing else: the
    /// countdown stands until the locator stops sending one.
    func testCancelDoesNotClearTheCountdown() {
        let m = LinkViewModel()
        m.setDeploymentTestActiveForTesting(true)
        m.ingestForTesting(countdownFrame(5))
        XCTAssertEqual(5, m.deploymentTestCountdown)

        m.noteDeploymentTestCancelSent()
        XCTAssertTrue(m.deploymentTestCancelPending, "the request is out and unanswered")
        XCTAssertEqual(5, m.deploymentTestCountdown, "the locator has not agreed to stop")
        XCTAssertTrue(m.deploymentTestActive, "the charge is still live")
    }

    /// A countdown that crossed the cancel in flight must not read as the cancel being
    /// refused — the countdown STOPPING is what settles that. So a later frame keeps the
    /// test alive and leaves the pending flag alone.
    func testACountdownArrivingAfterACancelKeepsTheTestLive() {
        let m = LinkViewModel()
        m.setDeploymentTestActiveForTesting(true)
        m.noteDeploymentTestCancelSent()

        m.ingestForTesting(countdownFrame(3))
        XCTAssertEqual(3, m.deploymentTestCountdown)
        XCTAssertTrue(m.deploymentTestActive)
        XCTAssertTrue(m.deploymentTestCancelPending, "still unanswered, not refused")
    }

    /// An unsolicited countdown belongs to a test this app did not start, and the screen
    /// has nothing useful to say about one.
    func testACountdownIsIgnoredWhileNoTestIsBelievedLive() {
        let m = LinkViewModel()
        m.ingestForTesting(countdownFrame(9))
        XCTAssertEqual(0, m.deploymentTestCountdown)
        XCTAssertFalse(m.deploymentTestActive)
    }

    // MARK: - The silence watchdog

    /// Silence is how all three endings look from here — canceled, fired, link lost — and
    /// all three mean the same thing for the screen.
    func testSilenceEndsTheTest() async {
        let m = LinkViewModel()
        m.setDeploymentTestSilenceForTesting(0.15)
        m.setDeploymentTestActiveForTesting(true)
        m.ingestForTesting(countdownFrame(2))
        m.noteDeploymentTestCancelSent()

        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(m.deploymentTestActive)
        XCTAssertEqual(0, m.deploymentTestCountdown)
        XCTAssertFalse(m.deploymentTestCancelPending)
    }

    /// Every countdown restarts it, so it fires only once the locator has genuinely gone
    /// quiet — not merely because a test has been running a while.
    func testEachCountdownRestartsTheWatchdog() async {
        let m = LinkViewModel()
        m.setDeploymentTestSilenceForTesting(0.3)
        m.setDeploymentTestActiveForTesting(true)

        for seconds in [5, 4, 3] {
            m.ingestForTesting(countdownFrame(seconds))
            try? await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(m.deploymentTestActive, "cleared while the locator was still counting")
        }
        XCTAssertEqual(3, m.deploymentTestCountdown)
    }

    /// The start frame can be lost too. Without the watchdog the screen would sit
    /// "active" for ever, waiting for a countdown that is never coming.
    func testAStartThatIsNeverAnsweredClearsItself() async {
        let m = LinkViewModel()
        m.setDeploymentTestSilenceForTesting(0.15)
        m.setDeploymentTestActiveForTesting(true)
        XCTAssertTrue(m.deploymentTestActive)

        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(m.deploymentTestActive)
    }

    /// Android's value, and the reason for it: it has to outlast the 1 Hz countdown with
    /// room for a dropped frame, without claiming a live charge long after the locator
    /// has stopped talking about one.
    func testTheSilenceWindowOutlastsTheCountdownRate() {
        XCTAssertEqual(3, LinkViewModel.deploymentTestSilenceForTesting)
    }

    // MARK: - Helpers

    private func countdownFrame(_ seconds: Int) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: WireProtocol.headerSize + 1)
        frame[0] = WireProtocol.systemId
        frame[1] = MsgType.deploymentTest.rawValue
        frame[WireProtocol.headerSize] = UInt8(seconds)
        return frame
    }
}
