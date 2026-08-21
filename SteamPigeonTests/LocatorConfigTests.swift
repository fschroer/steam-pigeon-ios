import XCTest
@testable import SteamPigeon

/// The locator settings struct, and the channel move that rides in it (ADR-0011).
///
/// A wrong offset here does not fail loudly — the locator length-validates the message
/// and drops it, which is indistinguishable from the command never arriving. That is
/// the failure #36 recorded, and the reason the size is pinned.
final class LocatorConfigTests: XCTestCase {

    private func config() -> LocatorConfig {
        LocatorConfig(
            deployChannelModes: [.droguePrimary, .drogueBackup, .mainPrimary, .mainBackup],
            launchDetectAltitude: 30,
            droguePrimaryDelay: 4,
            drogueBackupDelay: 7,
            mainPrimaryAltitude: 150,
            mainBackupAltitude: 120,
            deploySignalDuration: 10,
            loraChannel: 42,
            deviceName: "Rocket One",
            noseAxis: .z)
    }

    /// Both firmwares `static_assert` 45. Header 6 + target 4 + payload 35.
    func testTheWholeMessageIsFortyFiveBytes() {
        XCTAssertEqual(45, WireProtocol.locatorSettingsSize)
        XCTAssertEqual(WireProtocol.locatorSettingsSize,
                       WireProtocol.headerSize + 4 + config().payload.count)
    }

    /// Offsets are relative to the start of the payload, i.e. firmware offset − 10.
    func testFieldsAtTheirFirmwareOffsets() {
        let p = config().payload
        XCTAssertEqual([0, 1, 2, 3], Array(p[0..<4]), "deployment ch1..4 modes")
        XCTAssertEqual([30, 0], Array(p[4..<6]), "launch_detect_altitude, little-endian")
        XCTAssertEqual(4, p[6], "drogue primary delay")
        XCTAssertEqual(7, p[7], "drogue backup delay")
        XCTAssertEqual([150, 0], Array(p[8..<10]), "main primary altitude")
        XCTAssertEqual([120, 0], Array(p[10..<12]), "main backup altitude")
        XCTAssertEqual(10, p[12], "deploy signal duration")
        XCTAssertEqual(42, p[13], "lora_channel")
        XCTAssertEqual("Rocket One",
                       String(decoding: p[14..<34].prefix { $0 != 0 }, as: UTF8.self))
        XCTAssertEqual(NoseAxis.z.rawValue, p[34], "nose_axis is LAST, after the name")
    }

    /// `nose_axis` was appended after `device_name` so every existing field kept its
    /// offset — the receiver reads `lora_channel` BY OFFSET to follow a channel change
    /// (ADR-0011 invariant 2). Moving it would break the follow silently.
    func testLoraChannelKeepsTheOffsetTheReceiverReadsBy() {
        // Firmware offset 23 = header 6 + target 4 + payload index 13.
        XCTAssertEqual(23, WireProtocol.headerSize + 4 + 13)
    }

    /// A name longer than the field is truncated, not allowed to run into nose_axis.
    func testAnOverlongNameIsTruncatedRatherThanOverflowing() {
        var c = config()
        c.deviceName = String(repeating: "x", count: 40)
        let p = c.payload
        XCTAssertEqual(35, p.count)
        XCTAssertEqual(NoseAxis.z.rawValue, p[34])
    }

    // MARK: - The placeholders, and why they must match Android's

    /// `PreLaunchData` carries neither field, so the app cannot learn them — but the
    /// whole struct is sent, so every change WRITES them. They are the firmware
    /// defaults, so this is a no-op on an unmodified locator and a silent reset on one
    /// configured over the USB console.
    func testThePlaceholdersAreTheValuesAndroidWritesBack() {
        XCTAssertEqual(30, LocatorConfig.launchDetectAltitudePlaceholder)
        XCTAssertEqual(10, LocatorConfig.deploySignalDurationPlaceholder)
    }

    /// The move is confirmed by whole-object equality against a config rebuilt from the
    /// next broadcast. If the placeholders differed from the ones `from(_:)` fills in,
    /// nothing would ever compare equal and every change would report as
    /// unacknowledged — which is why they are constants shared by both paths rather
    /// than literals at two call sites.
    func testAConfigRebuiltFromABroadcastComparesEqualToOneSentOut() {
        var broadcast = PreLaunchData()
        broadcast.deployChannelModes = [.droguePrimary, .drogueBackup, .mainPrimary, .mainBackup]
        broadcast.droguePrimaryDelay = 4
        broadcast.drogueBackupDelay = 7
        broadcast.mainPrimaryAltitude = 150
        broadcast.mainBackupAltitude = 120
        broadcast.deviceName = "Rocket One"
        broadcast.noseAxis = .z
        broadcast.channel = 42          // receiver-appended: ADR-0011 invariant 3

        XCTAssertEqual(config(), LocatorConfig.from(broadcast))
    }

    /// ADR-0011 invariant 3: the channel comes from the RECEIVER-appended field, because
    /// a received broadcast proves the two share it. Reading a locator-side channel
    /// instead would confirm against a value the locator cannot report while split.
    func testTheChannelIsTakenFromTheReceiverAppendedField() {
        var broadcast = PreLaunchData()
        broadcast.channel = 17
        XCTAssertEqual(17, LocatorConfig.from(broadcast).loraChannel)
    }
}
