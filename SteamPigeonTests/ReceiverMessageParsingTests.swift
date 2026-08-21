import XCTest
@testable import SteamPigeon

/// Field-offset tests for the three receiver-sourced messages.
///
/// Same reasoning as `BroadcastParsingTests`: a wrong offset does not fail loudly, it
/// shifts every field after it and shows plausible nonsense. So these write at
/// **explicitly stated offsets taken from the receiver firmware struct**, not by
/// reusing the parser's own walk — and the offsets are quoted here so a reader can
/// check them against `MessageProtocol.hpp` without running anything.
final class ReceiverMessageParsingTests: XCTestCase {

    private func blank(_ type: MsgType, total: Int) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: total)
        f[0] = WireProtocol.systemId
        f[1] = type.rawValue
        return f
    }

    private func putName(_ s: String, _ f: inout [UInt8], _ o: Int, length: Int) {
        for (i, b) in Array(s.utf8).prefix(length).enumerated() { f[o + i] = b }
    }

    // MARK: - ReceiverInfo
    //
    // Receiver firmware, `static_assert(sizeof(ReceiverInfoMessage) == 30)`:
    //   6 lora_channel u8 | 7 device_name char[20] | 27 noise_floor i16 | 29 bad_frames u8

    func testReceiverInfoFieldsAtTheirFirmwareOffsets() throws {
        var f = blank(.receiverInfo, total: 30)
        f[6] = 42                                                   // lora_channel
        putName("Pad Receiver", &f, 7, length: WireProtocol.deviceNameLength)
        f[27] = 0x9C; f[28] = 0xFF                                  // noise_floor = -100
        f[29] = 7                                                   // bad_frames

        let m = try XCTUnwrap(ReceiverInfo.parse(f))
        XCTAssertEqual(42, m.channel)
        XCTAssertEqual("Pad Receiver", m.deviceName)
        XCTAssertEqual(-100, m.noiseFloor)
        XCTAssertEqual(7, m.badFrames)
    }

    /// The size the firmware asserts, and the size the framer expects.
    func testReceiverInfoIsThirtyBytesOnTheWire() {
        XCTAssertEqual(30, WireProtocol.headerSize + WireProtocol.receiverInfoPayloadSize)
    }

    /// A receiver flashed before `aee36fe` sends the 27-byte form with no noise floor
    /// and no bad-frame count. It must be REJECTED rather than parsed from whatever
    /// follows it in the buffer — the version skew that cost a debugging session.
    func testTheShortLegacyFormIsRejected() {
        var f = blank(.receiverInfo, total: 27)
        f[6] = 12
        putName("Old", &f, 7, length: WireProtocol.deviceNameLength)
        XCTAssertNil(ReceiverInfo.parse(f))
    }

    func testAnUnnamedReceiverParsesAsEmptyRatherThanFailing() throws {
        var f = blank(.receiverInfo, total: 30)
        f[6] = 1
        let m = try XCTUnwrap(ReceiverInfo.parse(f))
        XCTAssertEqual("", m.deviceName)
    }

    // MARK: - VersionInfo
    //
    // The locator sends header 6 + locator_version[64] (asserted 70); the RECEIVER
    // appends its own 64 before forwarding, so the app sees 6 + 64 + 64 = 134.

    func testVersionInfoCarriesBothHalves() throws {
        var f = blank(.versionInfo, total: 134)
        putName("locator-1.2.3", &f, 6, length: 64)
        putName("receiver-4.5.6", &f, 70, length: 64)

        let m = try XCTUnwrap(VersionInfo.parse(f))
        XCTAssertEqual("locator-1.2.3", m.locatorVersion)
        XCTAssertEqual("receiver-4.5.6", m.receiverVersion)
    }

    func testVersionInfoIsOneHundredAndThirtyFourBytesOnTheWire() {
        XCTAssertEqual(134, WireProtocol.headerSize + WireProtocol.versionInfoPayloadSize)
    }

    /// A receiver that has not yet heard a locator forwards an empty locator half.
    /// Empty means "not known yet", not "no version" — and must not fail the parse.
    func testAnUnknownLocatorVersionIsEmptyNotAFailure() throws {
        var f = blank(.versionInfo, total: 134)
        putName("receiver-4.5.6", &f, 70, length: 64)
        let m = try XCTUnwrap(VersionInfo.parse(f))
        XCTAssertEqual("", m.locatorVersion)
        XCTAssertEqual("receiver-4.5.6", m.receiverVersion)
    }

    // MARK: - ChannelSurvey
    //
    // Receiver firmware, `static_assert(sizeof(ChannelSurveyResponse) == 84)`:
    //   6 status u8 | 7 channel_count u8 | 8 home_channel u8 | 9 level i8[64]
    //   73 confirmed_count u8 | 74 confirmed_channel u8[5] | 79 confirmed_frames u8[5]

    private func surveyFrame(status: UInt8 = 0, home: UInt8 = 3,
                             levels: [Int8], confirmed: [UInt8], frames: [UInt8]) -> [UInt8] {
        var f = blank(.channelSurvey, total: 84)
        f[6] = status
        f[7] = UInt8(levels.count)
        f[8] = home
        for (i, v) in levels.enumerated() { f[9 + i] = UInt8(bitPattern: v) }
        f[73] = UInt8(confirmed.count)
        for (i, v) in confirmed.enumerated() { f[74 + i] = v }
        for (i, v) in frames.enumerated() { f[79 + i] = v }
        return f
    }

    func testChannelSurveyIsEightyFourBytesOnTheWire() {
        XCTAssertEqual(84, WireProtocol.headerSize + WireProtocol.channelSurveyPayloadSize)
        XCTAssertEqual(64, WireProtocol.surveyChannelCount)
        XCTAssertEqual(5, WireProtocol.surveyConfirmCount)
    }

    func testChannelSurveyFieldsAtTheirFirmwareOffsets() throws {
        var levels = [Int8](repeating: -110, count: 64)
        levels[9] = -55                                             // one loud channel
        levels[20] = -120                                           // the quietest
        let f = surveyFrame(home: 3, levels: levels,
                            confirmed: [20, 21, 3], frames: [0, 0, 4])

        let r = try XCTUnwrap(ChannelSurvey.parse(f))
        XCTAssertEqual(.ok, r.status)
        XCTAssertEqual(3, r.homeChannel)
        XCTAssertEqual(20, r.ranked.first?.channel, "quietest ranks first")
        XCTAssertEqual(9, r.ranked.last?.channel, "loudest ranks last")
        // Home decoded frames — ours — so it is not reported as another locator.
        XCTAssertTrue(r.homeChannelInUse)
        XCTAssertTrue(r.occupied.isEmpty)
        XCTAssertEqual([20, 21], r.suggestions.map(\.channel))
    }

    /// Levels are SIGNED. Reading them unsigned turns −55 dBm into +201 and inverts the
    /// entire ranking, which would confidently recommend the loudest channel in the band.
    func testLevelsAreSignedDbm() throws {
        var levels = [Int8](repeating: -110, count: 64)
        levels[0] = -55
        let f = surveyFrame(levels: levels, confirmed: [0], frames: [0])
        let r = try XCTUnwrap(ChannelSurvey.parse(f))
        XCTAssertEqual(-55, r.confirmed.first?.level)
    }

    func testARefusedSweepParsesAsRefusedRatherThanFailing() throws {
        let f = surveyFrame(status: 1, levels: [], confirmed: [], frames: [])
        let r = try XCTUnwrap(ChannelSurvey.parse(f))
        XCTAssertEqual(.refusedArmed, r.status)
        XCTAssertTrue(r.suggestions.isEmpty)
    }

    /// **A short or corrupt frame must not trap.** Swift traps on an out-of-range index
    /// rather than throwing, so a count the frame cannot back would take the app down
    /// mid-flight. Every count is bounded against the buffer.
    func testAShortOrLyingFrameDoesNotTrap() {
        var f = surveyFrame(levels: [Int8](repeating: -100, count: 64),
                            confirmed: [1, 2], frames: [0, 0])
        f[7] = 64                                                   // claims 64 levels…
        f[73] = 5                                                   // …and 5 confirmed
        // The assertion is that the process survives: an out-of-range index would trap
        // here, not return nil, so reaching the end of the loop IS the result.
        for cut in [9, 20, 60, 74, 79, 83] {
            _ = ChannelSurvey.parse(Array(f.prefix(cut)))
        }
        // Too short to carry even a status byte: nil, not a fabricated Result.
        XCTAssertNil(ChannelSurvey.parse([]))
    }
}
