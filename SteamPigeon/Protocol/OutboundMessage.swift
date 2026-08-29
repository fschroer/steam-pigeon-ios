import Foundation

/// Builds app→device frames.
///
/// **ADR-0020 is enforced here, not by convention.** Every app→locator command must
/// carry `target_locator_id` immediately after the header. Before that existed, a
/// channel change sent to one locator moved *both* locators on the channel, and
/// `LocatorCfgChgRequest` carries the whole `RocketPersistentSettings` — so a
/// bystander had its deployment channel modes, drogue delays, main deploy altitudes
/// and device name rewritten on a rocket the user never connected to. `ArmRequest`
/// was in the same class: on a shared launch channel, pressing Arm armed every
/// disarmed locator on it.
///
/// The locator discards anything not matching its UID before any state change, and
/// `0` matches nothing, so an older app fails closed. This builder therefore makes a
/// locator-directed message **impossible to construct without a target**, rather than
/// leaving it to the caller to remember.
enum OutboundMessage {

    /// Messages the receiver answers itself, with no locator involved. These carry no
    /// target because there is no locator to address.
    static let receiverDirected: Set<MsgType> = [
        .receiverCfgChgRequest,
        .receiverInfoRequest,
        .channelSurveyRequest,
        // Same reasoning as the survey, and more load-bearing: a search is started
        // precisely when no locator is connected, so treating it as locator-directed
        // would disable it in the only state it is for.
        .locatorSearchRequest,
    ]

    /// Build a receiver-directed message.
    ///
    /// - Returns: nil if `type` is locator-directed — use `locatorDirected` instead,
    ///   which requires a target.
    static func receiverDirected(_ type: MsgType, payload: [UInt8] = []) -> [UInt8]? {
        guard receiverDirected.contains(type) else { return nil }
        return frame(type, body: payload)
    }

    /// Build a locator-directed command, addressed to `targetLocatorId` (ADR-0020).
    ///
    /// - Returns: nil if `type` is receiver-directed, or if the target is 0 — which
    ///   matches no locator and would be a command that silently does nothing.
    static func locatorDirected(_ type: MsgType, targetLocatorId: UInt32,
                                payload: [UInt8] = []) -> [UInt8]? {
        guard !receiverDirected.contains(type), targetLocatorId != 0 else { return nil }
        return frame(type, body: u32le(targetLocatorId) + payload)
    }

    /// header (systemId, msgType, msgCount, crc) + body, with the CRC filled in last.
    private static func frame(_ type: MsgType, body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [
            WireProtocol.systemId,
            type.rawValue,
            0, 0,           // msgCount — the app sends 0, matching Android
            0, 0,           // crc placeholder; computed over the frame with these zeroed
        ]
        out += body
        let crc = PacketFramer.computeCrc(out)
        out[4] = UInt8(truncatingIfNeeded: crc)
        out[5] = UInt8(truncatingIfNeeded: crc >> 8)
        return out
    }

    /// `LocatorSearchRequest`: search `channels`, or the whole band when it is empty.
    ///
    /// `targetLocatorId` stops the run on the first frame from that locator; **0 means a
    /// census**, and that is the only thing that works for a borrowed locator the app has
    /// never heard of — not a fallback.
    ///
    /// The payload is always the full 22 bytes the firmware reads, zero-filled past the
    /// listed channels: the struct is fixed-size on the wire, and `channel_count` is what
    /// says how much of it means anything.
    static func locatorSearch(channels: [Int], targetLocatorId: UInt32 = 0) -> [UInt8]? {
        var payload = [UInt8](repeating: 0, count: WireProtocol.locatorSearchRequestPayloadSize)
        let listed = Array(channels.prefix(WireProtocol.searchMaxChannels))
        payload[0] = 0                                   // flags
        payload[1] = UInt8(clamping: listed.count)       // 0 = whole band
        for (i, byte) in u32le(targetLocatorId).enumerated() { payload[2 + i] = byte }
        for (i, channel) in listed.enumerated() { payload[6 + i] = UInt8(clamping: channel) }
        return receiverDirected(.locatorSearchRequest, payload: payload)
    }

    /// Stop a search in progress. Answered with a `Cancelled` terminator **even when
    /// nothing was running**, so the app never waits on silence to find out.
    static func cancelLocatorSearch() -> [UInt8]? {
        var payload = [UInt8](repeating: 0, count: WireProtocol.locatorSearchRequestPayloadSize)
        payload[0] = WireProtocol.searchFlagCancel
        return receiverDirected(.locatorSearchRequest, payload: payload)
    }

    static func u32le(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v),
         UInt8(truncatingIfNeeded: v >> 8),
         UInt8(truncatingIfNeeded: v >> 16),
         UInt8(truncatingIfNeeded: v >> 24)]
    }
}
