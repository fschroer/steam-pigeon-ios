import XCTest
@testable import SteamPigeon

/// ADR-0012 invariants. These encode a bug that reached a user, so they are written
/// as the behaviors the ADR names rather than as coverage of the implementation.
final class ConnectionHealthMonitorTests: XCTestCase {

    func testConstantsMatchTheAndroidReference() {
        XCTAssertEqual(10, ConnectionHealthMonitor.dataTimeout)
        XCTAssertEqual(3, ConnectionHealthMonitor.maxMissedProbes)
    }

    /// Invariant 1, the load-bearing one: silence must probe, never disconnect.
    func testFirstSilentWindowProbesRatherThanDisconnecting() {
        var m = ConnectionHealthMonitor()
        XCTAssertEqual(.sendProbe, m.windowElapsed())
    }

    /// Invariant 3: while the locator transmits, no probe is ever sent.
    func testNoProbeWhileDataIsFlowing() {
        var m = ConnectionHealthMonitor()
        for _ in 0..<50 {
            m.recordDataReceived()
            XCTAssertEqual(.none, m.windowElapsed())
        }
        XCTAssertEqual(0, m.missedProbes)
    }

    /// Invariant 2: phantom only after `maxMissedProbes` *consecutive* silent windows.
    func testPhantomOnlyAfterThreeConsecutiveUnansweredProbes() {
        var m = ConnectionHealthMonitor()
        XCTAssertEqual(.sendProbe, m.windowElapsed())       // ~10 s
        XCTAssertEqual(.sendProbe, m.windowElapsed())       // ~20 s
        XCTAssertEqual(.declarePhantom, m.windowElapsed())  // ~30 s
    }

    /// The regression that caused the disconnect/reconnect loop: an idle receiver that
    /// answers probes must stay connected forever, however long the locator is silent.
    func testIdleReceiverAnsweringProbesStaysConnectedIndefinitely() {
        var m = ConnectionHealthMonitor()
        for cycle in 0..<200 {
            XCTAssertEqual(.sendProbe, m.windowElapsed(), "cycle \(cycle) should probe")
            m.recordDataReceived()                       // the receiver answered
            XCTAssertEqual(.none, m.windowElapsed())
        }
    }

    /// Any inbound byte resets the counter, so misses must be consecutive. Two silent
    /// windows either side of one reply must not add up to a phantom verdict.
    func testAnswerResetsTheMissCounter() {
        var m = ConnectionHealthMonitor()
        XCTAssertEqual(.sendProbe, m.windowElapsed())
        XCTAssertEqual(.sendProbe, m.windowElapsed())
        XCTAssertEqual(2, m.missedProbes)

        m.recordDataReceived()
        XCTAssertEqual(0, m.missedProbes)

        // Starts over: two more silent windows still are not three.
        XCTAssertEqual(.none, m.windowElapsed())
        XCTAssertEqual(.sendProbe, m.windowElapsed())
        XCTAssertEqual(.sendProbe, m.windowElapsed())
    }

    /// Relayed locator traffic counts as much as a probe reply — the ADR routes all
    /// inbound data through the same call deliberately.
    func testRelayedLocatorTrafficCountsAsLiveness() {
        var m = ConnectionHealthMonitor()
        XCTAssertEqual(.sendProbe, m.windowElapsed())
        m.recordDataReceived()                            // telemetry, not a reply
        XCTAssertEqual(.none, m.windowElapsed())
        XCTAssertEqual(0, m.missedProbes)
    }

    func testResetClearsStateForAFreshLink() {
        var m = ConnectionHealthMonitor()
        _ = m.windowElapsed()
        _ = m.windowElapsed()
        XCTAssertEqual(2, m.missedProbes)
        m.reset()
        XCTAssertEqual(0, m.missedProbes)
        XCTAssertEqual(.sendProbe, m.windowElapsed(), "a reset link probes before it condemns")
    }

    /// Data arriving mid-window is enough; it need not arrive at the boundary.
    func testDataAnywhereInTheWindowCounts() {
        var m = ConnectionHealthMonitor()
        m.recordDataReceived()
        m.recordDataReceived()
        XCTAssertEqual(.none, m.windowElapsed())
    }
}
