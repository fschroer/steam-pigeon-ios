import Foundation

/// The receiver's own report of its channel, name and channel status.
///
/// Offsets from the RECEIVER firmware's `ReceiverInfoMessage`
/// (`steam-pigeon-receiver/Rocket/Communication/Inc/MessageProtocol.hpp`), which
/// `static_assert`s the total at 30 — header 6 + payload 24:
///
///     6  lora_channel u8 | 7  device_name char[20] | 27 noise_floor i16 | 29 bad_frames u8
///
/// **This is the only message the receiver sends with no locator involved**, which is
/// what makes it load-bearing twice over. It carries the channel-status noise floor
/// that ADR-0019 needs during locator silence — the one floor reading that does not
/// have to ride on a broadcast — and it is the ADR-0012 health probe's answer.
///
/// Worth knowing before debugging anything about it: a receiver flashed before
/// `aee36fe` sends the **27-byte** form with no `noise_floor` and no `bad_frames`, and
/// the app's CRC gate turns that version skew into silence rather than an error. Every
/// reply is discarded and the link still reports healthy, because ADR-0012 counts
/// liveness before framing. If the floor is missing, check the receiver's firmware
/// before suspecting this parser.
struct ReceiverInfo: Equatable {
    var channel: UInt8 = 0
    var deviceName = ""
    var noiseFloor: Int16 = 0
    var badFrames: UInt8 = 0

    static func parse(_ f: [UInt8]) -> ReceiverInfo? {
        guard f.count >= WireProtocol.headerSize + WireProtocol.receiverInfoPayloadSize
        else { return nil }

        var o = WireProtocol.headerSize
        var m = ReceiverInfo()

        guard let channel = Bytes.u8(f, o) else { return nil };  o += 1; m.channel = channel
        guard let name = Bytes.name(f, o, length: WireProtocol.deviceNameLength)
        else { return nil };                                    o += WireProtocol.deviceNameLength
        m.deviceName = name
        guard let floor = Bytes.i16(f, o) else { return nil };   o += 2; m.noiseFloor = floor
        guard let bad = Bytes.u8(f, o) else { return nil };      m.badFrames = bad

        return m
    }
}

/// Firmware versions, locator and receiver.
///
/// The LOCATOR sends `VersionInfoMessage` — header 6 + `locator_version[64]`, asserted
/// at 70. The RECEIVER appends its own 64 bytes before forwarding (`VersionInfoExtended`),
/// so what reaches the app is 6 + 64 + 64 = 134, payload 128.
///
/// Both fields are NUL-padded, and a receiver that has not yet heard a locator forwards
/// an empty locator half — so an empty string means "not known yet", not "no version".
struct VersionInfo: Equatable {
    var locatorVersion = ""
    var receiverVersion = ""

    static let fieldLength = 64

    static func parse(_ f: [UInt8]) -> VersionInfo? {
        guard f.count >= WireProtocol.headerSize + WireProtocol.versionInfoPayloadSize
        else { return nil }

        var o = WireProtocol.headerSize
        var m = VersionInfo()

        guard let locator = Bytes.name(f, o, length: Self.fieldLength) else { return nil }
        o += Self.fieldLength
        guard let receiver = Bytes.name(f, o, length: Self.fieldLength) else { return nil }

        m.locatorVersion = locator
        m.receiverVersion = receiver
        return m
    }
}
