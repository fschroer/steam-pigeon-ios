import XCTest
@testable import SteamPigeon

final class OutboundMessageTests: XCTestCase {

    /// The builder and the verifier must agree — a message we send has to satisfy the
    /// same CRC check we apply to everything we receive.
    func testBuiltMessagePassesTheReceiveSideCrcCheck() {
        let msg = OutboundMessage.receiverDirected(.receiverInfoRequest)
        XCTAssertNotNil(msg)
        XCTAssertTrue(PacketFramer.verifyCrc(msg!))
    }

    func testReceiverInfoRequestIsHeaderOnly() {
        let msg = OutboundMessage.receiverDirected(.receiverInfoRequest)!
        XCTAssertEqual(WireProtocol.headerSize, msg.count)
        XCTAssertEqual(WireProtocol.systemId, msg[0])
        XCTAssertEqual(MsgType.receiverInfoRequest.rawValue, msg[1])
    }

    // MARK: - ADR-0020 addressing

    /// A locator-directed command must be impossible to build without a target. This
    /// is the safety property: an unaddressed command reaches every locator on the
    /// channel, which once rewrote a bystander rocket's pyro configuration.
    func testLocatorCommandsCannotBeBuiltAsReceiverDirected() {
        for t in [MsgType.armRequest, .disarmRequest, .locatorCfgChgRequest,
                  .flightDataRequest, .padAlertSnoozeRequest] {
            XCTAssertNil(OutboundMessage.receiverDirected(t),
                         "\(t) is locator-directed and must require a target")
        }
    }

    /// Target 0 matches no locator, so a command carrying it silently does nothing.
    /// Refuse to build it rather than emit a command that cannot work.
    func testZeroTargetIsRefused() {
        XCTAssertNil(OutboundMessage.locatorDirected(.armRequest, targetLocatorId: 0))
    }

    func testReceiverMessagesCannotBeAddressedToALocator() {
        XCTAssertNil(OutboundMessage.locatorDirected(.receiverInfoRequest, targetLocatorId: 0x1234))
    }

    /// TargetedRequest is 10 bytes on the wire: header 6 + target 4.
    func testAddressedCommandMatchesTheFirmwareStructSize() {
        let msg = OutboundMessage.locatorDirected(.armRequest, targetLocatorId: 0xDEADBEEF)!
        XCTAssertEqual(10, msg.count)
        XCTAssertEqual(WireProtocol.headerSize + WireProtocol.targetLocatorIdSize, msg.count)
        XCTAssertTrue(PacketFramer.verifyCrc(msg))
    }

    /// The target sits immediately after the header, little-endian.
    func testTargetIsLittleEndianRightAfterTheHeader() {
        let msg = OutboundMessage.locatorDirected(.armRequest, targetLocatorId: 0xDEADBEEF)!
        XCTAssertEqual([0xEF, 0xBE, 0xAD, 0xDE], Array(msg[6..<10]))
    }

    /// FlightDataRequest and DeploymentTestRequest are header + target + one byte = 11.
    func testOnePayloadByteCommandIsElevenBytes() {
        let msg = OutboundMessage.locatorDirected(.flightDataRequest,
                                                  targetLocatorId: 7, payload: [3])!
        XCTAssertEqual(11, msg.count)
        XCTAssertTrue(PacketFramer.verifyCrc(msg))
    }

    /// Changing any byte must invalidate the CRC — otherwise the check is decorative.
    func testCrcCoversTheWholeFrame() {
        var msg = OutboundMessage.locatorDirected(.armRequest, targetLocatorId: 0xDEADBEEF)!
        for i in 0..<msg.count where i != 4 && i != 5 {
            var mutated = msg
            mutated[i] = mutated[i] &+ 1
            XCTAssertFalse(PacketFramer.verifyCrc(mutated), "byte \(i) is not covered by the CRC")
        }
        msg[6] = msg[6] &+ 1
        XCTAssertFalse(PacketFramer.verifyCrc(msg))
    }
}
