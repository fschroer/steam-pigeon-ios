import XCTest
@testable import SteamPigeon

/// Two connectivity defects reported from the phone on 2026-08-21, both of which
/// Android has never had:
///
/// 1. A locator **armed when the app starts** was received, authenticated and plotted,
///    and the status panel said "No Locator" the whole time.
/// 2. With **no receiver switched on at launch** the app scanned once, said so, and
///    never looked again — switching a receiver on changed nothing.
///
/// Both are the same shape: a state the app treats as final that Android treats as
/// something to keep working from.
@MainActor
final class ReceiverLocatorRecoveryTests: XCTestCase {

    // MARK: - 1. Naming a locator that is already armed

    /// The locator row's rule, in Android's order (`FlightMapScreen.kt`).
    ///
    /// The bug was the missing first case: the name was taken from `PreLaunchData`,
    /// which an armed locator never sends, so an empty name and a live locator were
    /// indistinguishable from an empty name and no locator at all.
    func testTheLocatorRowReportsAbsenceOnlyWhenNothingIsArriving() {
        XCTAssertEqual("Big Bertha",
                       MapStatusPanel.locatorText(name: "Big Bertha", fresh: true, state: .ready))
        XCTAssertEqual("No Locator",
                       MapStatusPanel.locatorText(name: nil, fresh: false, state: .ready))
    }

    /// A named locator that has gone quiet is absent, whatever it was called.
    func testAStaleNameIsNotReportedAsPresent() {
        XCTAssertEqual("No Locator",
                       MapStatusPanel.locatorText(name: "Big Bertha", fresh: false, state: .ready))
    }

    /// Broadcasts are arriving, and the app has no name for their sender — only
    /// `PreLaunchData` carries one, and this locator has been armed since before the
    /// app opened. Blank is the honest answer; "No Locator" contradicts the telemetry
    /// being plotted beside it, which is precisely what was reported.
    func testAnArrivingButUnnamedLocatorIsNotReportedAsAbsent() {
        XCTAssertEqual("", MapStatusPanel.locatorText(name: "", fresh: true, state: .ready))
        XCTAssertEqual("", MapStatusPanel.locatorText(name: nil, fresh: true, state: .ready))
    }

    /// With no receiver there is nothing to hear a locator THROUGH. Android gates this
    /// row on `Ready` so it cannot report the same single fault a second time.
    func testNoReceiverMeansTheLocatorRowSaysNothing() {
        for state: TransportState in [.idle, .scanning, .noDevicesFound, .poweredOff,
                                      .connecting, .connected, .disconnected] {
            XCTAssertEqual("", MapStatusPanel.locatorText(name: nil, fresh: false, state: state),
                           "\(state) already speaks for itself in the receiver row")
        }
    }

    /// The label is stored beside the password key, as Android's `KnownLocator.label`
    /// is — it is the only chance to learn the name, since the challenge is raised on a
    /// `PreLaunchData` the locator stops sending the moment it is armed.
    func testTheStoredLabelSurvivesWithTheKey() {
        let id: UInt32 = 0x0BAD_F00D
        var store = KnownLocatorStore()
        defer { store.forget(locatorId: id) }

        store.remember(locatorId: id, passwordKey: 42, label: "Big Bertha")
        XCTAssertEqual("Big Bertha", KnownLocatorStore().label(for: id),
                       "a fresh store must read back what the last one wrote")

        // An empty name means "not known here" — `TelemetryData` has no name field at
        // all — and must never overwrite one already held.
        store.remember(locatorId: id, passwordKey: 42, label: "")
        XCTAssertEqual("Big Bertha", KnownLocatorStore().label(for: id))
    }

    func testAForgottenLocatorLeavesNoLabelBehind() {
        let id: UInt32 = 0x0BAD_BEEF
        var store = KnownLocatorStore()
        store.remember(locatorId: id, passwordKey: 7, label: "Callisto")
        store.forget(locatorId: id)
        XCTAssertNil(KnownLocatorStore().label(for: id))
    }

    /// End to end, and the reported case exactly: nothing but `TelemetryData` has ever
    /// arrived, and the panel still has a name to show.
    func testAnArmedLocatorIsNamedFromTheStoredLabel() {
        let id: UInt32 = 0x51EA_1234
        var store = KnownLocatorStore()
        store.remember(locatorId: id, passwordKey: 0, label: "Big Bertha")
        defer { store.forget(locatorId: id) }

        let m = LinkViewModel()
        m.ingestForTesting(telemetryFrame(locatorId: id, key: 0))

        XCTAssertEqual(id, m.connectedLocatorId, "an armed locator authenticates on its own")
        XCTAssertEqual("Big Bertha", m.remoteLocatorConfig.deviceName)
    }

    /// The fallback fills a gap; it never argues with the locator. Android lets the
    /// first `PreLaunchData` overwrite the label with the live value.
    func testALiveNameIsNotReplacedByTheStoredLabel() {
        let id: UInt32 = 0x51EA_5678
        var store = KnownLocatorStore()
        store.remember(locatorId: id, passwordKey: 0, label: "Stale Name")
        defer { store.forget(locatorId: id) }

        let m = LinkViewModel()
        m.ingestForTesting(prelaunchFrame(locatorId: id, key: 0, deviceName: "Live Name"))
        XCTAssertEqual("Live Name", m.remoteLocatorConfig.deviceName)

        // ...and arming it — telemetry from here on — must not undo that.
        m.ingestForTesting(telemetryFrame(locatorId: id, key: 0))
        XCTAssertEqual("Live Name", m.remoteLocatorConfig.deviceName)
    }

    /// The reported case after the first fix: the locator has **no password**, so it was
    /// never authorized and Android would have stored no label for it either. The name
    /// is remembered from any accepted `PreLaunchData` instead, which is what makes an
    /// open locator nameable while armed.
    func testAnOpenLocatorHeardOnceIsNamedWhenItComesBackArmed() {
        let id: UInt32 = 0x09E4_0001
        var store = KnownLocatorStore()
        store.forget(locatorId: id)
        defer { store.forget(locatorId: id) }

        // Session one: heard disarmed, never challenged — nothing holds its password.
        let first = LinkViewModel()
        first.ingestForTesting(prelaunchFrame(locatorId: id, key: 0, deviceName: "Callisto"))
        XCTAssertEqual("Callisto", first.remoteLocatorConfig.deviceName)
        XCTAssertNil(KnownLocatorStore().keysById[id], "an open locator holds no password")

        // Session two: the app is opened with the rocket already armed, so nothing but
        // `TelemetryData` ever arrives.
        let second = LinkViewModel()
        second.ingestForTesting(telemetryFrame(locatorId: id, key: 0))
        XCTAssertEqual("Callisto", second.remoteLocatorConfig.deviceName)
    }

    /// **The conflict path names its locator too** — Android calls `noteLocatorName`
    /// before its `mayConnect` check (app `b209671`), so an authorized locator it
    /// declines to connect to is still remembered. iOS used to note the name only on
    /// `.accepted`, which lost exactly the two-rocket case: hear the second locator
    /// while the first holds the link, and the only broadcast that ever carried its name
    /// went unremembered — so switching to it after it was armed left the row blank.
    func testAnAuthorizedLocatorWeDeclineToConnectToIsStillNamed() {
        let first: UInt32 = 0x0C0F_0001
        let second: UInt32 = 0x0C0F_0002
        var store = KnownLocatorStore()
        store.forget(locatorId: first)
        store.forget(locatorId: second)
        defer { store.forget(locatorId: first); store.forget(locatorId: second) }

        let m = LinkViewModel()
        m.ingestForTesting(prelaunchFrame(locatorId: first, key: 0, deviceName: "Callisto"))
        XCTAssertEqual(first, m.connectedLocatorId)

        // The second rocket, authorized (open) but heard while the first still holds the
        // connection — the conflict path, not the accepted one.
        m.ingestForTesting(prelaunchFrame(locatorId: second, key: 0, deviceName: "Big Bertha"))
        XCTAssertEqual(first, m.connectedLocatorId, "the standing connection is not switched")
        XCTAssertEqual(second, m.conflictLocatorId, "this must be the conflict path")

        XCTAssertEqual("Big Bertha", KnownLocatorStore().label(for: second),
                       "the one broadcast that carried its name must have been remembered")
    }

    /// The other half of the same rule: an UNAUTHORIZED locator is not named. A name is
    /// only worth keeping for a locator this app is entitled to display, and Android
    /// stores one only inside its `authorized` branch.
    func testAnUnauthorizedLocatorIsNotNamed() {
        let id: UInt32 = 0x0C0F_0003
        var store = KnownLocatorStore()
        store.forget(locatorId: id)
        defer { store.forget(locatorId: id) }

        let m = LinkViewModel()
        m.ingestForTesting(prelaunchFrame(locatorId: id, key: 0xABCD_1234,
                                          deviceName: "Stranger"))
        XCTAssertNotEqual(id, m.connectedLocatorId)
        XCTAssertNil(KnownLocatorStore().label(for: id))
    }

    /// `PreLaunchData` arrives at 1 Hz. Re-writing the same name to `UserDefaults` at
    /// that rate is churn, so an unchanged name is not a write.
    func testARepeatedNameIsNotWrittenAgain() {
        let id: UInt32 = 0x0BAD_CAFE
        var store = KnownLocatorStore()
        defer { store.forget(locatorId: id) }

        XCTAssertTrue(store.noteName(locatorId: id, name: "Callisto"))
        XCTAssertFalse(store.noteName(locatorId: id, name: "Callisto"))
        XCTAssertFalse(store.noteName(locatorId: id, name: ""), "an empty name is not news")
        XCTAssertTrue(store.noteName(locatorId: id, name: "Callisto II"), "a rename is")
    }

    // MARK: - 2. Keeping on looking for a receiver

    /// The defect: one 3 s window at launch and then nothing. Android feeds
    /// `NoDevicesAvailable` straight back into `startScan()`, so a receiver switched on
    /// afterwards is found within a window.
    func testAnEmptyScanWindowIsFollowedByAnother() {
        XCTAssertTrue(BluetoothTransport.shouldResumeScanning(after: .noDevicesFound))
    }

    /// The same symptom from the other direction: a receiver switched off mid-session
    /// left the app on "Disconnected" until the user found Rescan. Android reconnects
    /// with a backoff and falls back to a scan; this app remembers no receiver by
    /// design, so the scan IS that fallback.
    func testALostReceiverIsLookedForAgain() {
        XCTAssertTrue(BluetoothTransport.shouldResumeScanning(after: .disconnected))
    }

    /// Scanning must not restart on top of itself or on top of a live link — and it
    /// cannot help when the radio is off, unauthorized or absent, where CoreBluetooth
    /// drops the command anyway and `centralManagerDidUpdateState` restarts the scan
    /// once the radio returns.
    func testScanningIsNotRestartedWhenItWouldBeWrongOrUseless() {
        for state: TransportState in [.idle, .scanning, .connecting, .connected, .ready,
                                      .poweredOff, .unauthorized, .unsupported] {
            XCTAssertFalse(BluetoothTransport.shouldResumeScanning(after: state),
                           "\(state) must not trigger a scan")
        }
    }

    /// The receiver names itself two ways and only one of them survives an armed
    /// locator: the BLE device name is a property of the link, while the configured name
    /// is learned from `PreLaunchData`. Reading only the second is what left the row
    /// saying "Connected" for the whole flight. Android's order, BLE name first.
    func testTheReceiverIsNamedByItsBleNameFirst() {
        XCTAssertEqual("SP Receiver 1",
                       LinkViewModel.receiverDisplayName(bleName: "SP Receiver 1",
                                                         configuredName: "Configured"))
        XCTAssertEqual("Configured",
                       LinkViewModel.receiverDisplayName(bleName: nil,
                                                         configuredName: "Configured"))
        XCTAssertEqual("Configured",
                       LinkViewModel.receiverDisplayName(bleName: "",
                                                         configuredName: "Configured"))
        XCTAssertNil(LinkViewModel.receiverDisplayName(bleName: nil, configuredName: ""),
                     "with no name at all the row falls through to the connection state")
    }

    /// Wording follows behaviour: the app is now waiting rather than reporting a
    /// verdict, which is what Android's `NoDevicesAvailable` row says.
    func testTheEmptyWindowIsWordedAsWaiting() {
        XCTAssertEqual("Waiting for receiver",
                       MapStatusPanel.receiverText(name: nil, state: .noDevicesFound))
    }

    // MARK: - Frames

    /// A telemetry frame authenticated under `key` — 83 bytes: the 77-byte base struct
    /// plus the six the receiver appends.
    private func telemetryFrame(locatorId: UInt32, key: UInt32) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 83)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.telemetryData.rawValue
        writeU32(&f, at: 69, locatorId)
        seal(&f, at: 73, key: key, baseSize: WireProtocol.telemetryBaseStructSize)
        return f
    }

    /// A pre-launch frame carrying `deviceName`, authenticated under `key`.
    private func prelaunchFrame(locatorId: UInt32, key: UInt32, deviceName: String) -> [UInt8] {
        var f = [UInt8](repeating: 0,
                        count: WireProtocol.headerSize + WireProtocol.prelaunchMessagePayloadSize)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.preLaunchData.rawValue
        // 13 bytes follow the name inside the authenticated struct: battery (2), nose
        // axis, armed, pad alert, then `locator_id` and `auth_tag` (4 each). See the
        // offsets asserted in `PreLaunchData.parse`.
        let nameOffset = WireProtocol.prelaunchBaseStructSize - 13 - WireProtocol.deviceNameLength
        for (i, b) in Array(deviceName.utf8).prefix(WireProtocol.deviceNameLength).enumerated() {
            f[nameOffset + i] = b
        }
        writeU32(&f, at: WireProtocol.prelaunchBaseStructSize - 8, locatorId)
        seal(&f, at: WireProtocol.prelaunchBaseStructSize - 4, key: key,
             baseSize: WireProtocol.prelaunchBaseStructSize)
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
