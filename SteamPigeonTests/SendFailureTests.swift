import CoreBluetooth
import XCTest
@testable import SteamPigeon

/// **A write that never left the phone was reported as `Sent`.**
///
/// `BluetoothTransport.send` returns false when the peripheral, the write characteristic
/// or the `.ready` state is missing, and it is marked `@discardableResult` — so all 17
/// call sites in `LinkViewModel` ignored it and the compiler never complained.
/// `changeReceiverConfig` set `.sent` unconditionally on the line after the call.
///
/// The user-visible cost was five seconds of nothing followed by the wrong diagnosis: a
/// generic read-back timeout saying "the receiver did not acknowledge" for a message that
/// was never sent. Android has always branched on the result
/// (`RocketViewModel.pointReceiverAtChannel`, `moveLocatorToChannel`,
/// `BluetoothService.changeLocatorArmedState`, `getFlightProfileData`).
///
/// Recorded in `docs/UI_PARITY.md` as "a gap found while auditing the Android owes list".
/// These are the cases that could not be written before `LocatorTransport` existed.
@MainActor
final class SendFailureTests: XCTestCase {

    /// A transport that accepts nothing, which is what a real one does with no receiver
    /// connected — the state this whole class of bug hides in.
    private final class DeadTransport: LocatorTransport {
        var onFrame: (([UInt8]) -> Void)?
        var onStateChange: ((TransportState) -> Void)?
        var onNameChange: ((String?) -> Void)?
        var onDiscover: (([CBPeripheral]) -> Void)?
        var onHealthProbe: (() -> Void)?
        var onBadFrameCount: ((Int) -> Void)?
        var onReject: ((PacketFramer.Reject) -> Void)?
        var onDroppedWrites: ((Int) -> Void)?
        var connectedName: String?

        private(set) var attempted = 0
        var accepts = false

        func send(_ bytes: [UInt8]) -> Bool { attempted += 1; return accepts }
        func startScan() {}
        func connectToDiscovered(_ id: UUID) {}
        func disconnect() {}
    }

    private let ours: UInt32 = 0x1111_1111

    private var defaults: UserDefaults!
    private var transport: DeadTransport!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SendFailureTests.\(UUID().uuidString)")!
        transport = DeadTransport()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
        transport = nil
        super.tearDown()
    }

    private func model() -> LinkViewModel {
        LinkViewModel(defaults: defaults, transport: transport)
    }

    /// Connected, so the command gates pass and the only thing left to fail is the write.
    private func connectedModel() -> LinkViewModel {
        let m = model()
        transport.accepts = true
        m.ingestForTesting(prelaunchFrame(locatorId: ours, key: 0, deviceName: "Twist 0",
                                          channel: 34))
        XCTAssertEqual(ours, m.connectedLocatorId, "precondition: connected")
        transport.accepts = false
        return m
    }

    func testAReceiverConfigChangeThatNeverWentOutReportsFailure() {
        let m = connectedModel()
        m.changeReceiverConfig(ReceiverConfig(channel: 57, deviceName: "Rx"))
        XCTAssertEqual(.sendFailure, m.receiverConfigMessageState,
                       "reported as Sent, this surfaced 5 s later as a read-back timeout")
        XCTAssertEqual(1, transport.attempted)
    }

    func testAReceiverConfigChangeThatWentOutReportsSent() {
        let m = connectedModel()
        transport.accepts = true
        m.changeReceiverConfig(ReceiverConfig(channel: 57, deviceName: "Rx"))
        XCTAssertEqual(.sent, m.receiverConfigMessageState)
    }

    func testALocatorConfigChangeThatNeverWentOutReportsFailure() {
        let m = connectedModel()
        var target = m.remoteLocatorConfig
        target.loraChannel = 57
        m.changeLocatorConfig(target)
        XCTAssertEqual(.sendFailure, m.locatorConfigMessageState)
    }

    /// The one with a rocket on a pad in front of it. An Arm that silently does nothing
    /// is the worst version of this bug: the icon blinks, so the app looks like it is
    /// waiting for an acknowledgement that cannot come.
    func testAnArmCommandThatNeverWentOutDoesNotBlinkForAnAcknowledgement() {
        let m = connectedModel()
        m.toggleArmed()
        XCTAssertFalse(m.armCommandPending,
                       "nothing was sent, so there is nothing to acknowledge")
        XCTAssertNotNil(m.transientMessage, "and the user has to be told")
    }

    func testAnArmCommandThatWentOutDoesBlink() {
        let m = connectedModel()
        transport.accepts = true
        m.toggleArmed()
        XCTAssertTrue(m.armCommandPending)
        XCTAssertNil(m.transientMessage)
    }

    func testAFlightDataRequestThatNeverWentOutReportsFailure() {
        let m = connectedModel()
        m.openFlightProfile(position: 0)
        XCTAssertEqual(.sendFailure, m.flightProfileDataState)
    }

    /// The metadata request reports the send rather than the attempt, which is what its
    /// retry loop reads to choose between `.sent` and `.sendFailure`.
    func testTheMetadataRequestReportsWhetherItWentOut() {
        let m = connectedModel()
        XCTAssertFalse(m.requestFlightProfileMetadata())
        transport.accepts = true
        XCTAssertTrue(m.requestFlightProfileMetadata())
    }

    // MARK: -

    /// A pre-launch frame carrying `deviceName` and the receiver's `channel`,
    /// authenticated under `key`. Same builder as `ChannelChangeRecognitionTests`.
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
