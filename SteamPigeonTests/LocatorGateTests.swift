import XCTest
@testable import SteamPigeon

/// ADR-0006 recognition-gate invariants.
///
/// These encode two bugs that reached hardware: the display alternating between two
/// rockets packet by packet, and the gate doing nothing at all against a second
/// *open* locator. Written as the behaviours the ADR names.
final class LocatorGateTests: XCTestCase {

    private let base = WireProtocol.telemetryBaseStructSize

    /// Build a telemetry frame authenticated under `key`, carrying `locatorId`.
    private func frame(locatorId: UInt32, key: UInt32) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 83)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.telemetryData.rawValue
        for i in 6..<69 { f[i] = UInt8(truncatingIfNeeded: i &* 5 &+ 1) }
        // locator_id at 69, auth_tag at 73 (last field of the 77-byte base struct)
        f[69] = UInt8(truncatingIfNeeded: locatorId)
        f[70] = UInt8(truncatingIfNeeded: locatorId >> 8)
        f[71] = UInt8(truncatingIfNeeded: locatorId >> 16)
        f[72] = UInt8(truncatingIfNeeded: locatorId >> 24)
        let tag = LocatorAuth.expectedAuthTag(frame: f, passwordKey: key, baseSize: base)!
        f[73] = UInt8(truncatingIfNeeded: tag)
        f[74] = UInt8(truncatingIfNeeded: tag >> 8)
        f[75] = UInt8(truncatingIfNeeded: tag >> 16)
        f[76] = UInt8(truncatingIfNeeded: tag >> 24)
        return f
    }

    // MARK: - mayConnect, the pure decision

    func testFreeSlotAcceptsAnyone() {
        XCTAssertTrue(LocatorConnection.mayConnect(connected: nil, sender: 1, age: 0))
    }

    func testHolderKeepsItsOwnConnection() {
        XCTAssertTrue(LocatorConnection.mayConnect(connected: 7, sender: 7, age: 0))
    }

    func testDifferentLocatorIsRefusedWhileTheHolderIsLive() {
        XCTAssertFalse(LocatorConnection.mayConnect(connected: 7, sender: 8, age: 14.9))
    }

    func testDifferentLocatorMayTakeOverAfterTheHoldExpires() {
        XCTAssertTrue(LocatorConnection.mayConnect(connected: 7, sender: 8, age: 15.0))
    }

    func testHoldIsFifteenSecondsAndLongerThanTheLinkUpTest() {
        XCTAssertEqual(15, LocatorConnection.connectionHold)
        XCTAssertGreaterThan(LocatorConnection.connectionHold, 5,
                             "releasing early puts another rocket's data on screen mid-flight")
    }

    // MARK: - Authorization is a set

    func testOpenLocatorAuthenticatesWithNoStoredPassword() {
        var gate = LocatorGate()
        XCTAssertEqual(.accepted(100),
                       gate.evaluate(frame: frame(locatorId: 100, key: 0), locatorId: 100, baseSize: base))
    }

    func testKnownPasswordAuthorizes() {
        let key = LocatorAuth.deriveKey("launch42")
        var gate = LocatorGate(knownKeys: [200: key])
        XCTAssertEqual(.accepted(200),
                       gate.evaluate(frame: frame(locatorId: 200, key: key), locatorId: 200, baseSize: base))
    }

    func testWrongPasswordIsUnauthorized() {
        var gate = LocatorGate(knownKeys: [300: LocatorAuth.deriveKey("wrong")])
        let f = frame(locatorId: 300, key: LocatorAuth.deriveKey("right"))
        XCTAssertEqual(.unauthorized(300), gate.evaluate(frame: f, locatorId: 300, baseSize: base))
    }

    /// Holding two passwords is normal — anyone with two locators is authorized for
    /// both. Authorization is a set; only the connection is exclusive.
    func testTwoLocatorsCanBothBeAuthorized() {
        let k1 = LocatorAuth.deriveKey("one"), k2 = LocatorAuth.deriveKey("two")
        let gate = LocatorGate(knownKeys: [1: k1, 2: k2])
        XCTAssertTrue(gate.isAuthorized(frame: frame(locatorId: 1, key: k1), locatorId: 1, baseSize: base))
        XCTAssertTrue(gate.isAuthorized(frame: frame(locatorId: 2, key: k2), locatorId: 2, baseSize: base))
    }

    // MARK: - The regressions this gate exists to prevent

    /// THE bug: two OPEN locators, where a global "recognized" slot did nothing at
    /// all. The second must be reported as conflict and must NOT take the display.
    func testSecondOpenLocatorDoesNotSeizeTheDisplay() {
        var gate = LocatorGate()
        XCTAssertEqual(.accepted(111),
                       gate.evaluate(frame: frame(locatorId: 111, key: 0), locatorId: 111, baseSize: base))
        XCTAssertEqual(.conflict(222),
                       gate.evaluate(frame: frame(locatorId: 222, key: 0), locatorId: 222, baseSize: base))
        XCTAssertEqual(111, gate.connectedLocatorId, "an arriving packet must never reassign the connection")
    }

    /// The display must not alternate packet by packet, however long the two
    /// interleave — the symptom that started this.
    func testAlternatingBroadcastsDoNotFlipTheConnection() {
        var gate = LocatorGate()
        _ = gate.evaluate(frame: frame(locatorId: 111, key: 0), locatorId: 111, baseSize: base)
        for _ in 0..<50 {
            XCTAssertEqual(.conflict(222),
                           gate.evaluate(frame: frame(locatorId: 222, key: 0), locatorId: 222, baseSize: base))
            XCTAssertEqual(.accepted(111),
                           gate.evaluate(frame: frame(locatorId: 111, key: 0), locatorId: 111, baseSize: base))
        }
        XCTAssertEqual(111, gate.connectedLocatorId)
    }

    /// After the holder goes quiet for the hold, another authorized locator may take
    /// over — a genuine power-down must not lock the app out forever.
    func testConnectionIsReleasedAfterTheHolderGoesSilent() {
        var gate = LocatorGate()
        let t0 = Date()
        _ = gate.evaluate(frame: frame(locatorId: 111, key: 0), locatorId: 111, baseSize: base, now: t0)
        XCTAssertEqual(.conflict(222),
                       gate.evaluate(frame: frame(locatorId: 222, key: 0), locatorId: 222,
                                     baseSize: base, now: t0.addingTimeInterval(14)))
        XCTAssertEqual(.accepted(222),
                       gate.evaluate(frame: frame(locatorId: 222, key: 0), locatorId: 222,
                                     baseSize: base, now: t0.addingTimeInterval(15)))
        XCTAssertEqual(222, gate.connectedLocatorId)
    }

    /// Every accepted frame refreshes the clock, so a live holder is never displaced
    /// however long the session runs.
    func testLiveHolderIsNeverDisplaced() {
        var gate = LocatorGate()
        var t = Date()
        _ = gate.evaluate(frame: frame(locatorId: 111, key: 0), locatorId: 111, baseSize: base, now: t)
        for _ in 0..<100 {
            t = t.addingTimeInterval(1)
            _ = gate.evaluate(frame: frame(locatorId: 111, key: 0), locatorId: 111, baseSize: base, now: t)
            XCTAssertEqual(.conflict(222),
                           gate.evaluate(frame: frame(locatorId: 222, key: 0), locatorId: 222,
                                         baseSize: base, now: t))
        }
    }

    // MARK: - Commands

    /// Commands are gated on CONNECTED, not merely authorized: they are addressed by
    /// the receiver's channel, so an Arm gated on the weaker condition could land on
    /// the wrong rocket.
    func testCommandsAreGatedOnConnectedNotAuthorized() {
        var gate = LocatorGate()
        _ = gate.evaluate(frame: frame(locatorId: 111, key: 0), locatorId: 111, baseSize: base)
        _ = gate.evaluate(frame: frame(locatorId: 222, key: 0), locatorId: 222, baseSize: base)

        XCTAssertTrue(gate.isAuthorized(frame: frame(locatorId: 222, key: 0), locatorId: 222, baseSize: base),
                      "222 is authorized")
        XCTAssertFalse(gate.mayCommand(222), "but must not be commandable — it is not connected")
        XCTAssertTrue(gate.mayCommand(111))
    }

    /// An explicit user switch is the one thing that moves a live connection.
    func testExplicitSwitchTakesTheConnection() {
        var gate = LocatorGate()
        _ = gate.evaluate(frame: frame(locatorId: 111, key: 0), locatorId: 111, baseSize: base)
        gate.connect(to: 222)
        XCTAssertEqual(222, gate.connectedLocatorId)
        XCTAssertTrue(gate.mayCommand(222))
        XCTAssertFalse(gate.mayCommand(111))
    }

    /// An armed locator authenticates from TelemetryData alone — that is what lets
    /// the app recognize a locator it has never heard a PreLaunchData from. Before
    /// the pair was added, opening the app mid-flight showed "No Locator" throughout.
    func testArmedLocatorIsRecognizedFromTelemetryAlone() {
        var gate = LocatorGate()
        let f = frame(locatorId: 999, key: 0)
        XCTAssertEqual(.accepted(999),
                       gate.evaluate(frame: f, locatorId: 999,
                                     baseSize: WireProtocol.telemetryBaseStructSize))
    }
}
