import CoreBluetooth
import XCTest
@testable import SteamPigeon

/// **The Firmware row on both settings screens was permanently blank.**
///
/// `LocatorSettingsView` and `ReceiverSettingsView` have carried
/// `if let version = model.versionInfo … Text("Firmware: \(…)")` since they were ported,
/// in Android's position and with Android's wording. The message type, the parser and the
/// framer entry were all in place too. Nothing ever sent the request, so `versionInfo`
/// stayed nil and both rows stayed hidden — the one missing link in an otherwise complete
/// chain, and invisible precisely because both screens hide the row while it is empty.
///
/// Ported from Android's `RocketViewModel` version job (`versionJob` / `connectionJob`)
/// and `BluetoothService.requestVersionInfo`.
@MainActor
final class FirmwareVersionTests: XCTestCase {

    /// Records what was sent, and lets a test drive the transport's callbacks.
    private final class RecordingTransport: LocatorTransport {
        var onFrame: (([UInt8]) -> Void)?
        var onStateChange: ((TransportState) -> Void)?
        var onNameChange: ((String?) -> Void)?
        var onDiscover: (([CBPeripheral]) -> Void)?
        var onHealthProbe: (() -> Void)?
        var onBadFrameCount: ((Int) -> Void)?
        var onReject: ((PacketFramer.Reject) -> Void)?
        var onDroppedWrites: ((Int) -> Void)?
        var connectedName: String?

        private(set) var sent: [[UInt8]] = []

        func send(_ bytes: [UInt8]) -> Bool { sent.append(bytes); return true }
        func startScan() {}
        func connectToDiscovered(_ id: UUID) {}
        func disconnect() {}

        var versionRequests: Int {
            sent.filter { $0.count > 1 && $0[1] == MsgType.versionRequest.rawValue }.count
        }
    }

    private let ours: UInt32 = 0x1111_1111

    private var defaults: UserDefaults!
    private var transport: RecordingTransport!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "FirmwareVersionTests.\(UUID().uuidString)")!
        transport = RecordingTransport()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
        transport = nil
        super.tearDown()
    }

    /// Connected to `ours` with the transport reporting `.ready`, which is the only state
    /// the tick will send from.
    private func readyModel() async -> LinkViewModel {
        let m = LinkViewModel(defaults: defaults, transport: transport)
        // The real path: the transport reports the link up, exactly as CoreBluetooth
        // would. Its callbacks hop to the main actor via `Task`, so let that land.
        transport.onStateChange?(.ready)
        try? await Task.sleep(for: .milliseconds(20))
        m.ingestForTesting(prelaunchFrame(locatorId: ours, key: 0, deviceName: "Twist 0",
                                          channel: 34))
        XCTAssertEqual(ours, m.connectedLocatorId, "precondition: connected")
        XCTAssertEqual(.ready, m.state, "precondition: the link is up")
        return m
    }

    // MARK: - The fix

    /// The whole defect in one case: a live link, no version known, and a request goes out.
    func testAConnectedLocatorIsAskedForItsFirmwareVersion() async {
        let m = await readyModel()
        m.versionTickForTesting()
        XCTAssertEqual(1, transport.versionRequests,
                       "nothing ever sent this, which is why the Firmware row was blank")
    }

    /// The request is locator-directed (ADR-0020), so it carries the connected locator's
    /// id and cannot go out with nothing connected — the same gate Android's `sendMessage`
    /// applies by refusing any locator-directed message without a `connectedLocatorId`.
    func testNothingIsAskedWithNoLocatorConnected() async {
        let m = LinkViewModel(defaults: defaults, transport: transport)
        transport.onStateChange?(.ready)
        try? await Task.sleep(for: .milliseconds(20))
        m.versionTickForTesting()
        XCTAssertEqual(0, transport.versionRequests)
    }

    /// One request fills BOTH rows: the receiver forwards it, the locator answers with its
    /// version, and the receiver appends its own before relaying.
    func testOneAnswerPopulatesBothSettingsScreens() async {
        let m = await readyModel()
        m.versionTickForTesting()
        m.ingestForTesting(versionFrame(locator: "loc-1.4.2", receiver: "rx-0.9.1"))

        XCTAssertEqual("loc-1.4.2", m.versionInfo?.locatorVersion)
        XCTAssertEqual("rx-0.9.1", m.versionInfo?.receiverVersion)
        XCTAssertFalse(m.isVersionInfoStaleForTesting)
    }

    // MARK: - The steady state is silent

    func testNothingIsAskedOnceTheVersionIsKnown() async {
        let m = await readyModel()
        m.versionTickForTesting()
        m.ingestForTesting(versionFrame(locator: "loc-1.4.2", receiver: "rx-0.9.1"))

        let now = Date().addingTimeInterval(60)
        for i in 0..<10 { m.versionTickForTesting(now: now.addingTimeInterval(Double(i))) }
        XCTAssertEqual(1, transport.versionRequests,
                       "a version loop that keeps transmitting is a request every few "
                       + "seconds forever")
    }

    /// Android waits 5 s after each request. Expressed here as a floor between sends,
    /// because this is a tick rather than a suspending loop.
    ///
    /// The locator has to keep broadcasting throughout, which is what really happens at
    /// 1 Hz: the silence window is also 5 s, so a link left untended goes down at exactly
    /// the moment the back-off expires and the tick would be right to stay quiet.
    func testAnUnansweredRequestIsNotRepeatedFasterThanTheBackoff() async {
        let m = await readyModel()
        let t0 = Date()
        m.setLastLocatorMessageForTesting(t0)
        m.versionTickForTesting(now: t0)
        m.versionTickForTesting(now: t0.addingTimeInterval(1))
        m.versionTickForTesting(now: t0.addingTimeInterval(4.9))
        XCTAssertEqual(1, transport.versionRequests, "still inside the 5 s back-off")

        // A broadcast lands, as one does every second, so the link is still up.
        m.setLastLocatorMessageForTesting(t0.addingTimeInterval(5))
        m.versionTickForTesting(now: t0.addingTimeInterval(5.1))
        XCTAssertEqual(2, transport.versionRequests, "and it does keep asking")
    }

    // MARK: - Reflash detection

    /// A rising edge on the link is the reflash signal: flashing takes the locator off the
    /// air. Without this a locator reflashed mid-session reports the version it booted
    /// with until the app is restarted.
    func testTheLinkComingBackReAsks() async {
        let m = await readyModel()
        let t0 = Date()
        m.setLastLocatorMessageForTesting(t0)
        m.versionTickForTesting(now: t0)
        m.ingestForTesting(versionFrame(locator: "loc-1.4.2", receiver: "rx-0.9.1"))
        XCTAssertEqual(1, transport.versionRequests)

        // The locator goes off the air — being reflashed, say — for longer than the
        // silence window.
        let quiet = t0.addingTimeInterval(30)
        m.versionTickForTesting(now: quiet)
        XCTAssertEqual(1, transport.versionRequests, "nothing to ask while it is silent")
        XCTAssertFalse(m.isVersionInfoStaleForTesting, "silence alone is not a reflash")

        // ...and comes back. That rising edge is the signal.
        m.setLastLocatorMessageForTesting(quiet.addingTimeInterval(10))
        m.versionTickForTesting(now: quiet.addingTimeInterval(10))
        XCTAssertEqual(2, transport.versionRequests, "it may have been reflashed meanwhile")
    }

    /// The receiver can only be reflashed across a BLE drop, which the LoRa edge cannot
    /// see — the locator may keep transmitting throughout.
    func testALinkLossMarksTheStampStaleWithoutBlankingIt() async {
        let m = await readyModel()
        m.versionTickForTesting()
        m.ingestForTesting(versionFrame(locator: "loc-1.4.2", receiver: "rx-0.9.1"))
        XCTAssertFalse(m.isVersionInfoStaleForTesting)

        m.clearLiveReadoutsForTesting()
        XCTAssertTrue(m.isVersionInfoStaleForTesting)
        // Blanking these would flicker the row on every brief dropout, since both screens
        // hide it while empty. The stale stamp stands until a newer one replaces it.
        XCTAssertEqual("loc-1.4.2", m.versionInfo?.locatorVersion)
        XCTAssertEqual("rx-0.9.1", m.versionInfo?.receiverVersion)
    }

    // MARK: -

    /// A `VersionInfo` frame: two 64-byte NUL-padded strings after the header.
    private func versionFrame(locator: String, receiver: String) -> [UInt8] {
        var f = [UInt8](repeating: 0,
                        count: WireProtocol.headerSize + WireProtocol.versionInfoPayloadSize)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.versionInfo.rawValue
        let o = WireProtocol.headerSize
        for (i, b) in Array(locator.utf8).prefix(VersionInfo.fieldLength).enumerated() {
            f[o + i] = b
        }
        for (i, b) in Array(receiver.utf8).prefix(VersionInfo.fieldLength).enumerated() {
            f[o + VersionInfo.fieldLength + i] = b
        }
        return f
    }

    /// Same builder as `ChannelChangeRecognitionTests`.
    private func prelaunchFrame(locatorId: UInt32, key: UInt32,
                                deviceName: String, channel: UInt8) -> [UInt8] {
        var f = [UInt8](repeating: 0,
                        count: WireProtocol.headerSize + WireProtocol.prelaunchMessagePayloadSize)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.preLaunchData.rawValue
        let nameOffset = WireProtocol.prelaunchBaseStructSize - 13 - WireProtocol.deviceNameLength
        for (i, b) in Array(deviceName.utf8).prefix(WireProtocol.deviceNameLength).enumerated() {
            f[nameOffset + i] = b
        }
        writeU32(&f, at: WireProtocol.prelaunchBaseStructSize - 8, locatorId)
        seal(&f, at: WireProtocol.prelaunchBaseStructSize - 4, key: key,
             baseSize: WireProtocol.prelaunchBaseStructSize)
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
