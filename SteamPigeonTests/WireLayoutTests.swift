import XCTest
@testable import SteamPigeon

/// Wire-layout cross-check — the **third leg of the test triad**.
///
/// The expected values below MUST equal the C++ `static_assert`s in
/// `MessageProtocol.hpp` (locator and receiver) and the Android `WireLayoutTest.kt`.
/// If a firmware struct changes, its `static_assert` fails the firmware build;
/// update the literal there AND the matching value in both apps. If an app constant
/// drifts without updating the firmware, this test fails. Together the three sides
/// keep the hand-written wire format in sync.
///
///     app payload size = sizeof(C++ struct) − header (6) [+ receiver-appended bytes]
///
/// Ported from `WireLayoutTest.kt`; verified against locator and receiver
/// `MessageProtocol.hpp` at locator `4a4202d`.
final class WireLayoutTests: XCTestCase {

    func testHeaderSize() {
        XCTAssertEqual(6, WireProtocol.headerSize)
    }

    // Receiver-appended link-quality trailer, present on both broadcasts (ADR-0019):
    // rssi 2 + snr 1 + noise_floor 2 + bad_frames 1. The receiver pins the extended
    // struct sizes (147 / 83) with its own static_asserts.
    private let linkTrailer = 6

    // PreLaunchData: C++ sizeof 118 → payload 112 (101 + nose_axis 1 + armed 1
    //                + pad_alert 1 + locator_id 4 + auth_tag 4);
    //                + channel 1 + recv battery 2 + recv name 20 + link trailer 6 = 141
    func testPrelaunchPayloadSize() {
        XCTAssertEqual(141, WireProtocol.prelaunchMessagePayloadSize)
    }

    func testPrelaunchBaseStructSize() {
        XCTAssertEqual(118, WireProtocol.prelaunchBaseStructSize)
    }

    // TelemetryData: C++ sizeof 77 → payload 71 (62 + armed 1 + locator_id 4
    //                + auth_tag 4); + link trailer 6 = 77
    func testTelemetryPayloadSize() {
        XCTAssertEqual(77, WireProtocol.telemetryMessagePayloadSize)
    }

    func testTelemetryBaseStructSize() {
        XCTAssertEqual(77, WireProtocol.telemetryBaseStructSize)
    }

    /// Both authenticated broadcasts put `auth_tag` last, and `LocatorAuth` locates it
    /// by offset from the end of the base struct — so the base size must be exactly
    /// the payload minus whatever the receiver appends after it. Getting this wrong
    /// does not fail to parse; it silently authenticates the wrong bytes.
    func testTelemetryBaseIsPayloadLessAppendedTrailer() {
        XCTAssertEqual(
            WireProtocol.telemetryBaseStructSize,
            WireProtocol.headerSize + WireProtocol.telemetryMessagePayloadSize - linkTrailer
        )
    }

    // Same relationship on the pre-launch side. The receiver appends channel 1 +
    // battery 2 + name 20 on top of the link trailer, so the excluded region is
    // larger — but the base struct is still exactly what the auth_tag covers.
    func testPrelaunchBaseIsPayloadLessAppendedMetadata() {
        let receiverAppended = 1 + 2 + WireProtocol.deviceNameLength + linkTrailer
        XCTAssertEqual(
            WireProtocol.prelaunchBaseStructSize,
            WireProtocol.headerSize + WireProtocol.prelaunchMessagePayloadSize - receiverAppended
        )
    }

    /// `noise_floor` is an `int16_t`, so the firmware's `kNoiseFloorUnknown`
    /// (`INT16_MIN`) arrives as −32768. On Android, comparing it against
    /// `Int.MIN_VALUE` silently never matched, so "no sample" was read as a real
    /// floor and poisoned the baseline.
    func testNoiseFloorUnknownMatchesInt16Min() {
        XCTAssertEqual(Int(Int16.min), LinkQuality.noiseFloorUnknown)
    }

    // ReceiverInfo: channel 1 + name 20 + noise_floor 2 + bad_frames 1 = 24
    // (C++ sizeof(ReceiverInfoMessage) 30, asserted in the receiver's
    // MessageProtocol.hpp). The trailing channel status is the only noise-floor
    // reading that reaches the app without a locator broadcast to ride on.
    //
    // The app frames this message by exact length BEFORE checking its CRC, so a
    // drift desynchronises the framer instead of failing a check: it waits for
    // bytes that never come, the health probe goes unanswered, and the watchdog
    // declares a phantom connection and reconnects in a loop.
    func testReceiverInfoPayloadSize() {
        XCTAssertEqual(24, WireProtocol.receiverInfoPayloadSize)
    }

    func testReceiverInfoPayloadIsItsParts() {
        XCTAssertEqual(
            WireProtocol.receiverInfoPayloadSize,
            1 + WireProtocol.deviceNameLength + 2 + 1
        )
    }

    // VersionInfo: locator 64 + receiver 64 = 128
    func testVersionInfoPayloadSize() {
        XCTAssertEqual(128, WireProtocol.versionInfoPayloadSize)
    }

    // ChannelSurveyResponse: C++ sizeof 84 → payload 78 (status 1 + channel_count 1
    // + home_channel 1 + level[64] + confirmed_count 1 + confirmed_channel[5]
    // + confirmed_frames[5]).
    func testChannelSurveyPayloadSize() {
        XCTAssertEqual(78, WireProtocol.channelSurveyPayloadSize)
    }

    func testSurveyChannelCount() {
        XCTAssertEqual(64, WireProtocol.surveyChannelCount)
    }

    func testSurveyConfirmCount() {
        XCTAssertEqual(5, WireProtocol.surveyConfirmCount)
    }

    func testChannelSurveyPayloadIsItsParts() {
        XCTAssertEqual(
            WireProtocol.channelSurveyPayloadSize,
            3 + WireProtocol.surveyChannelCount + 1 + 2 * WireProtocol.surveyConfirmCount
        )
    }

    // ── Addressed app→locator commands (ADR-0020) ───────────────────────────────
    // Every command carries target_locator_id right after the header. The locator
    // discards anything not addressed to its UID, so a size mismatch here does not
    // merely garble a command — it makes every command silently do nothing.

    // FlightDataAck: the builder still produces the 42-byte body (header 6 +
    // transfer_id 2 + packet_count 2 + bitmap 32); the send path splices the target
    // in, so the C++ sizeof is 46.
    func testFlightDataAckSize() {
        XCTAssertEqual(42, FlightDataSizes.flightDataAckSize)
    }

    func testFlightDataAckOnWireCarriesTheTarget() {
        XCTAssertEqual(46, FlightDataSizes.flightDataAckSize + WireProtocol.targetLocatorIdSize)
    }

    // Formerly header-only, now header + target: C++ sizeof(TargetedRequest) == 10.
    // Covers ArmRequest, DisarmRequest, FlightMetadataRequest, VersionRequest.
    func testTargetedRequestSize() {
        XCTAssertEqual(10, WireProtocol.headerSize + WireProtocol.targetLocatorIdSize)
    }

    // FlightDataRequest and DeploymentTestRequest: header + target + one byte == 11.
    func testOnePayloadByteCommandSize() {
        XCTAssertEqual(11, WireProtocol.headerSize + WireProtocol.targetLocatorIdSize + 1)
    }

    // FlightMetadata: 9 records × 10 bytes = 90 payload (C++ sizeof 96).
    // 9, was 10, since locator ARCHIVE_VERSION 6.
    func testFlightMetadataPayloadSize() {
        XCTAssertEqual(90, FlightDataSizes.flightMetadataPayloadSize)
    }

    // FlightEvents: C++ sizeof 66 → payload 60 (record 1 + reserved 1 +
    // present_mask 2 + flight_timestamp_s 4 + event_timestamp_ms[11] 44 +
    // max_altitude_m 4 + deployment_ch_stats[4] 4)
    func testFlightEventsPayloadSize() {
        XCTAssertEqual(60, WireProtocol.flightEventsPayloadSize)
    }

    // The event count is baked into the payload size above and into the wire order
    // shared with the firmware's Communication::FlightEvent enum.
    func testFlightEventCount() {
        XCTAssertEqual(11, FlightEventIndex.allCases.count)
    }

    // The 11 event timestamps are the bulk of the FlightEvents payload; if the enum
    // and the payload size ever disagree, one of the two copies moved alone.
    func testFlightEventsPayloadIsItsParts() {
        XCTAssertEqual(
            WireProtocol.flightEventsPayloadSize,
            1 + 1 + 2 + 4 + (4 * FlightEventIndex.allCases.count) + 4 + 4
        )
    }

    // Wire order is the contract, not a display preference.
    func testFlightEventWireOrder() {
        XCTAssertEqual(0, FlightEventIndex.launch.rawValue)
        XCTAssertEqual(1, FlightEventIndex.burnout.rawValue)
        XCTAssertEqual(2, FlightEventIndex.apogee.rawValue)
        XCTAssertEqual(10, FlightEventIndex.landing.rawValue)
    }

    // FlightDataPacket: max LoRa frame = 256 on the app side
    func testMaxPacketSize() {
        XCTAssertEqual(256, WireProtocol.maxPacketSize)
    }

    // ---------------------------------------------------------------------
    //  LocatorCfgChgRequest body — the one message the app builds byte by byte
    // ---------------------------------------------------------------------
    //
    // C++ sizeof(LocatorSettings) == 45 = header 6 + target 4 +
    // sizeof(RocketPersistentSettings) 35. The receiver ALSO pins 45, on its own
    // LocatorRocketSettings, and length-validates the relay against it — a drift
    // silently drops every config change the app sends, which is indistinguishable
    // from the command never arriving.
    //
    // Ported from Android `WireLayoutTest.kt` at app `b6c67ad` ("reserved config
    // fields v1"), case for case, so the third leg of the triad covers this body too.

    private var cfg: LocatorConfig {
        LocatorConfig(
            deployChannelModes: [.droguePrimary, .drogueBackup, .mainPrimary, .mainBackup],
            droguePrimaryDelay: 3,
            drogueBackupDelay: 20,
            mainPrimaryAltitude: 130,
            mainBackupAltitude: 100,
            loraChannel: 7,
            deviceName: "Pigeon 1",
            noseAxis: .x)
    }

    func testLocatorConfigBodySize() {
        XCTAssertEqual(35, cfg.payload.count)
        XCTAssertEqual(LocatorConfig.payloadSize, cfg.payload.count)
    }

    func testLocatorConfigOnWireMatchesTheFirmwareStruct() {
        XCTAssertEqual(45, WireProtocol.headerSize + 4 + cfg.payload.count)
    }

    // The receiver reads this ONE byte out of the relayed frame, by offsetof, to
    // follow the locator onto a new channel (ADR-0011 invariant 5). If it moves, the
    // receiver retunes to whatever byte now sits there and the link splits — with the
    // locator out of reach by definition.
    func testLoraChannelSitsWhereTheReceiverReadsIt() {
        XCTAssertEqual(7, cfg.payload[LocatorConfig.loraChannelOffset])
        XCTAssertEqual(13, LocatorConfig.loraChannelOffset)
    }

    // launch_detect_altitude (u16 @4) and deploy_signal_duration (u8 @12) are
    // reserved: the app does not set them and the locator keeps its own (ADR-0028).
    // They carry the firmware defaults rather than zeros, because a locator running
    // firmware from before that change still adopts whatever arrives here, and for it
    // zero means launch detected at 0 m AGL and a pyro signal held for 0 s.
    func testReservedSlotsCarryTheFirmwareDefaultsNotZero() {
        let body = cfg.payload
        XCTAssertEqual(30, UInt16(body[4]) | (UInt16(body[5]) << 8))
        XCTAssertEqual(10, body[12])
        XCTAssertEqual(LocatorConfig.reservedLaunchDetectAltitudeM, 30)
        XCTAssertEqual(LocatorConfig.reservedDeploySignalDurationTenths, 10)
    }

    // The whole body, so any field moving is caught rather than only the two offsets
    // named above. Byte for byte the same expectation as Android's.
    func testLocatorConfigBodyLayout() {
        var expected: [UInt8] = [
            0, 1, 2, 3,        // deployment_ch1..4_mode
            30, 0,             // launch_detect_altitude — reserved (u16 le)
            3,                 // drogue_primary_deploy_delay
            20,                // drogue_backup_deploy_delay
            130, 0,            // main_primary_deploy_altitude (u16 le)
            100, 0,            // main_backup_deploy_altitude (u16 le)
            10,                // deploy_signal_duration — reserved
            7,                 // lora_channel
        ]
        expected += Array("Pigeon 1".utf8)
        expected += [UInt8](repeating: 0, count: 12)    // device_name[20], zero-filled
        expected.append(NoseAxis.x.rawValue)
        XCTAssertEqual(35, expected.count)
        XCTAssertEqual(expected, cfg.payload)
    }
}
