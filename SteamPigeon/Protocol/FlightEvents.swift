import Foundation

/// One deployment channel's stat byte, as the locator packs it into `FlightEvents`.
///
/// Bit layout mirrors the locator's `Constants.hpp` `bit_shift_*` values, and the
/// three continuity/fired bits are what the chart's indicator circles draw: an
/// outlined "fired" beside a filled pre-fire continuity says the charge had
/// continuity and never got a fire command, which is a different failure from a
/// charge that had no continuity to begin with.
struct DeployChannelStats: Equatable {
    var mode: DeployMode = .unused
    var fired = false
    var preFireContinuity = false
    var postFireContinuity = false

    static func from(_ raw: UInt8) -> DeployChannelStats {
        DeployChannelStats(
            mode:               DeployMode.from(raw & 0x07),
            fired:              raw & (1 << 3) != 0,
            preFireContinuity:  raw & (1 << 4) != 0,
            postFireContinuity: raw & (1 << 5) != 0)
    }
}

/// Per-record flight event summary (`MsgType.flightEvents`), sent by the locator
/// alongside the flight profile data for the record being viewed.
///
/// **Only event *times* cross the wire.** Altitudes are resolved against the profile
/// samples for the same record — see `resolveEvents` — so a marker always sits
/// exactly on the plotted trace rather than on a second, separately-quantised idea
/// of where the rocket was.
struct FlightEvents: Equatable {
    /// Archive slot this summary describes. −1 means "nothing received yet", which is
    /// why it is not 0: slot 0 is a real record.
    var record: Int = -1
    /// One bit per `FlightEventIndex`. An event outside the mask was NOT recorded,
    /// which is a different thing from an event recorded at time 0 — the launch
    /// itself is normally at 0 ms.
    var presentMask: Int = 0
    var flightTimestampS: UInt32 = 0
    var eventTimestampMs: [Int] = []
    var maxAltitudeM: Float = 0
    var channelStats: [DeployChannelStats] = []

    /// Launch wall-clock time, or nil if the locator had no GPS fix.
    var launchDate: Date? {
        flightTimestampS > 0 ? Date(timeIntervalSince1970: TimeInterval(flightTimestampS)) : nil
    }

    /// Timestamp for `event`, or nil when the locator did not record it.
    func timestampMs(_ event: FlightEventIndex) -> Int? {
        guard presentMask & (1 << event.rawValue) != 0 else { return nil }
        return eventTimestampMs.indices.contains(event.rawValue)
            ? eventTimestampMs[event.rawValue] : nil
    }

    /// The 1-based channel assigned to `mode`, or nil if no channel was configured for it.
    func channel(for mode: DeployMode) -> Int? {
        guard let index = channelStats.firstIndex(where: { $0.mode == mode }) else { return nil }
        return index + 1
    }

    var isEmpty: Bool { record < 0 || presentMask == 0 }

    /// Decode a `flightEvents` frame (MsgType 19).
    ///
    /// Field order and offsets mirror the firmware's `Communication::FlightEventsMessage`
    /// exactly; the total is pinned by `WireProtocol.flightEventsPayloadSize` and
    /// `WireLayoutTests`. Returns nil for a short frame — a truncated one would
    /// otherwise decode as garbage event times and scatter markers across the chart.
    static func parse(_ frame: [UInt8]) -> FlightEvents? {
        guard frame.count >= WireProtocol.headerSize + WireProtocol.flightEventsPayloadSize
        else { return nil }

        var o = WireProtocol.headerSize

        guard let record = Bytes.u8(frame, o) else { return nil }; o += 1
        o += 1                                                    // reserved
        guard let mask = Bytes.u16(frame, o) else { return nil };  o += 2
        guard let flightTsS = Bytes.u32(frame, o) else { return nil }; o += 4

        var timestamps: [Int] = []
        timestamps.reserveCapacity(FlightEventIndex.allCases.count)
        for i in 0..<FlightEventIndex.allCases.count {
            guard let t = Bytes.u32(frame, o + i * 4) else { return nil }
            timestamps.append(Int(t))
        }
        o += FlightEventIndex.allCases.count * 4

        guard let maxAltitude = Bytes.f32(frame, o) else { return nil }; o += 4

        var stats: [DeployChannelStats] = []
        for i in 0..<4 {
            guard let raw = Bytes.u8(frame, o + i) else { return nil }
            stats.append(.from(raw))
        }

        return FlightEvents(
            record:           Int(record),
            presentMask:      Int(mask),
            flightTimestampS: flightTsS,
            eventTimestampMs: timestamps,
            maxAltitudeM:     maxAltitude,
            channelStats:     stats)
    }
}
