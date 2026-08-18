import Foundation

/// Wire-format constants for the Steam Pigeon link.
///
/// This is the **third** hand-maintained copy of the wire format. The other two are
/// the firmware `static_assert`s in `MessageProtocol.hpp` (locator *and* receiver)
/// and the Android app's `Protocol` object in `RocketState.kt`. Per ADR "iOS port —
/// CoreBluetooth and platform parity", all three change in the **same session**,
/// cross-referencing commit hashes. `WireLayoutTests` pins these values so a drift
/// fails the build here rather than silently mis-parsing a frame in the field.
///
/// Named `WireProtocol` rather than `Protocol` (the Kotlin name) only because
/// `Protocol` is taken by the ObjC runtime type imported via Foundation.
enum WireProtocol {

    /// systemId 1 + msgType 1 + msgCount 2 + crc 2.
    /// Firmware: `sizeof(PacketHeader) == 6`.
    static let headerSize = 6

    static let systemId: UInt8 = 0x44

    /// Bytes the **receiver** appends to both locator broadcasts (ADR-0019):
    /// rssi 2 + snr 1 + noise_floor 2 + bad_frames 1.
    static let linkTrailerSize = 6

    /// Bytes carried after the header in a relayed `PreLaunchData`:
    /// base payload 112 + channel 1 + receiver battery 2 + receiver name 20
    /// + link trailer 6. Receiver: `sizeof(PreLaunchMessageExtended) == 147`.
    static let prelaunchMessagePayloadSize = 141

    /// On-wire size of the locator's `PreLaunchData` struct (header 6 + payload 112).
    /// The auth_tag is computed over exactly these bytes, with crc and auth_tag
    /// zeroed; receiver-appended metadata sits after and is excluded. The armed
    /// byte is inside this region, so it is authenticated (ADR-0021).
    static let prelaunchBaseStructSize = 118

    /// Relayed `TelemetryData`: base payload 71 + link trailer 6.
    /// Receiver: `sizeof(TelemetryMessageExtended) == 83`.
    static let telemetryMessagePayloadSize = 77

    /// On-wire size of the locator's `TelemetryData` struct (header 6 + payload 71).
    /// Carries the same trailing `locator_id` + `auth_tag` pair as `PreLaunchData`,
    /// which is what lets an *armed* locator be recognized from telemetry alone.
    static let telemetryBaseStructSize = 77

    /// status 1 + channel_count 1 + home_channel 1 + level[64]
    /// + confirmed_count 1 + confirmed_channel[5] + confirmed_frames[5].
    /// Receiver: `sizeof(ChannelSurveyResponse) == 84`.
    static let channelSurveyPayloadSize = 78
    static let surveyChannelCount = 64
    static let surveyConfirmCount = 5

    /// channel 1 + name 20 + noise_floor 2 + bad_frames 1.
    /// Receiver: `sizeof(ReceiverInfoMessage) == 30`.
    ///
    /// The app frames this message by exact length **before** checking its CRC, so a
    /// drift desynchronises the framer rather than failing a check: it waits for
    /// bytes that never come, the health probe goes unanswered, and the watchdog
    /// declares a phantom connection and reconnects in a loop.
    static let receiverInfoPayloadSize = 24

    /// locator version 64 + receiver version 64. The locator sends
    /// `sizeof(VersionInfoMessage) == 70` (header 6 + 64); the receiver appends its own.
    static let versionInfoPayloadSize = 128

    /// record 1 + reserved 1 + present_mask 2 + flight_timestamp_s 4
    /// + event_timestamp_ms[11] 44 + max_altitude_m 4 + deployment_ch_stats[4] 4.
    /// Locator: `sizeof(FlightEventsMessage) == 66`.
    static let flightEventsPayloadSize = 60

    /// Maximum LoRa frame on the app side. The firmware pins
    /// `sizeof(FlightDataPacket) == 255`; the app buffers 256.
    static let maxPacketSize = 256

    static let deviceNameLength = 20

    /// `target_locator_id` carried by every app→locator command (ADR-0020). The
    /// locator discards anything not matching its UID **before any state change**,
    /// and 0 matches nothing, so an older app fails closed.
    static let targetLocatorIdSize = 4
}
