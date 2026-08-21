import Foundation

/// The receiver's band sweep, ranked into a recommendation (ADR-0019 tier 3).
///
/// Two rules from the ADR shape everything here.
///
/// **Rank relatively; never present absolute dBm as truth.** SX126x RSSI near the noise
/// floor is uncalibrated and varies unit to unit, so a level means something only
/// against the other levels in the *same* sweep.
///
/// **Detect the all-channels-hot case.** A locator sitting a few feet from the receiver
/// saturates the front end on every channel at once. Ranking that blindly would
/// confidently recommend whichever channel happened to read lowest, which is worthless
/// advice — the fix is to move the nearby transmitter, not to change channel. That is
/// the exact scenario that prompted this whole line of work.
enum ChannelSurvey {

    /// Mirrors the receiver firmware's `ChannelSurveyStatus`.
    ///
    /// An unrecognised byte is `unknown`, never `ok`: levels are meaningless unless the
    /// receiver said the sweep succeeded, and a value this build cannot interpret must
    /// not present as a good reading.
    enum Status: Equatable {
        case ok, refusedArmed, refusedBusy, unknown

        static func from(_ v: UInt8) -> Status {
            switch v {
            case 0:  return .ok
            case 1:  return .refusedArmed      // locator armed — sweeping would drop telemetry
            case 2:  return .refusedBusy       // flight-data transfer in progress
            default: return .unknown
            }
        }
    }

    /// Even the quietest channel reading above this means the receiver is swamped
    /// broadband — almost always a transmitter within a few feet. A genuinely quiet
    /// channel sits far below it.
    static let allHotDbm = -90

    /// Spread across the confirmed channels below which an elevated reading is a
    /// *uniform* floor rather than real per-channel traffic.
    ///
    /// The confirm dwell exceeds one broadcast period, so it always overlaps a
    /// transmission — and a locator within a few feet bleeds across the whole band while
    /// transmitting, so every confirmed channel reads at the bleed level. That is the
    /// normal bench condition and says nothing about the channels themselves.
    ///
    /// Measured on two bench traces: a locator ~2 ft away with genuine co-channel
    /// traffic gave −52/−57/−71/−71/−71 — 19 dB, real structure. The same locator
    /// further off with no co-channel traffic gave −71/−74/−72/−71/−71 — 3 dB, flat.
    /// 6 dB sits well clear of both.
    static let uniformSpreadDb = 6

    /// How many channels the recommendation offers.
    static let suggestionCount = 5

    /// One channel's reading. `frames` is locator broadcasts DECODED during its confirm
    /// dwell, or 0 for channels that were never confirmed.
    struct Ranked: Equatable {
        let channel: Int
        let level: Int
        var frames: Int = 0

        /// A decoded frame had to be transmitted on this exact channel — off-channel
        /// bleed does not survive the demodulator. So this is occupancy as fact rather
        /// than inference, and it outranks the level completely.
        ///
        /// The converse does NOT hold: zero frames does not prove empty. The dwell is
        /// one broadcast period, so a sparser emitter slips through, and a non-locator
        /// device is invisible to this test entirely — which is what the level is for.
        var occupiedByLocator: Bool { frames > 0 }
    }

    struct Result: Equatable {
        let status: Status
        /// Quietest first. Empty unless `status` is `.ok`.
        let ranked: [Ranked]
        /// True when every confirmed channel is loud.
        let allChannelsHot: Bool
        /// True when every confirmed channel is loud *and* within `uniformSpreadDb` of
        /// each other — a broadband floor from a nearby transmitter rather than traffic
        /// on any particular channel. Information, not a fault: the channels are
        /// genuinely indistinguishable, so any of them is as good as another.
        let uniformFloor: Bool
        let homeChannel: Int
        /// Channels the receiver dwelled on for a full broadcast period. **Only these
        /// are evidence that a channel is free**: the coarse pass dwells ~12 ms while a
        /// locator is on air ~138 ms per second, so it reads an occupied channel as
        /// quiet about three times in four.
        let confirmed: [Ranked]

        /// Channels to offer, quietest first.
        ///
        /// Drawn from `confirmed` only, never the coarse ranking — suggesting an
        /// unconfirmed channel is how a sweep ends up recommending the one the locators
        /// are already sitting on. A bench sweep did exactly that.
        ///
        /// Offered **even when `allChannelsHot`**. The broadband floor makes everything
        /// read loud, but the ranking underneath is still correct and the caller still
        /// has to choose something; withholding them leaves a correct warning with no
        /// way to act on it. The warning is shown alongside, not instead.
        var suggestions: [Ranked] {
            guard status == .ok else { return [] }
            // A channel with a locator decoded on it is occupied whatever its level
            // says. That is the whole point of the frame count: RSSI cannot separate
            // "a locator is using this channel" from "a locator near me is loud on
            // every channel", and this can.
            return Array(confirmed.filter { !$0.occupiedByLocator }.prefix(suggestionCount))
        }

        /// Confirmed channels with a locator on them, **excluding home**. Home is always
        /// confirmed and normally decodes frames, because that is where our own locator
        /// transmits; reporting it as "another locator" would be plainly wrong.
        var occupied: [Ranked] {
            confirmed.filter { $0.occupiedByLocator && $0.channel != homeChannel }
        }

        /// Whether a locator was decoded on the channel we are using. With a locator
        /// connected this is expected — it is ours, and it confirms the scan measures
        /// what it claims to. With none connected, someone else is on your channel.
        var homeChannelInUse: Bool {
            confirmed.contains { $0.channel == homeChannel && $0.occupiedByLocator }
        }

        /// Where the current channel sits in the ranking, 1-based. Nil if unknown.
        var homeRank: Int? {
            ranked.firstIndex { $0.channel == homeChannel }.map { $0 + 1 }
        }
    }

    /// - Parameters:
    ///   - levels: peak dBm per channel, index == channel number.
    static func analyze(status: Status,
                        levels: [Int],
                        homeChannel: Int,
                        confirmedChannels: [Int] = [],
                        confirmedFrames: [Int] = []) -> Result {
        guard status == .ok, !levels.isEmpty else {
            return Result(status: status, ranked: [], allChannelsHot: false,
                          uniformFloor: false, homeChannel: homeChannel, confirmed: [])
        }

        // Stable tie-break on channel number, so an unchanged RF environment produces
        // an unchanged recommendation rather than shuffling on every sweep.
        let ranked = levels.enumerated()
            .map { Ranked(channel: $0.offset, level: $0.element) }
            .sorted { ($0.level, $0.channel) < ($1.level, $1.channel) }

        let confirmed = confirmedChannels.enumerated()
            .filter { levels.indices.contains($0.element) }
            .map { Ranked(channel: $0.element,
                          level: levels[$0.element],
                          frames: confirmedFrames.indices.contains($0.offset)
                                  ? confirmedFrames[$0.offset] : 0) }
            .sorted { ($0.level, $0.channel) < ($1.level, $1.channel) }

        // Judged on the confirmed set, since those are the only readings that mean
        // anything. If every channel actually verified is loud, the receiver is swamped
        // broadband and no channel change will help.
        let allHot = !confirmed.isEmpty && confirmed[0].level >= allHotDbm
        let spread = confirmed.isEmpty ? 0 : confirmed[confirmed.count - 1].level - confirmed[0].level
        return Result(status: status, ranked: ranked, allChannelsHot: allHot,
                      uniformFloor: allHot && spread <= uniformSpreadDb,
                      homeChannel: homeChannel, confirmed: confirmed)
    }

    /// Decode a `ChannelSurveyResponse`.
    ///
    /// Offsets from the RECEIVER firmware, which `static_assert`s the total at 84 —
    /// header 6 + payload 78:
    ///
    ///     6 status u8 | 7 channel_count u8 | 8 home_channel u8 | 9 level i8[64]
    ///     73 confirmed_count u8 | 74 confirmed_channel u8[5] | 79 confirmed_frames u8[5]
    ///
    /// **Every count from the frame is trusted only as far as the buffer allows.**
    /// Android bounds each one the same way, and in Swift it matters more: an
    /// out-of-range index traps rather than throwing, so a short or corrupt frame would
    /// take the app down mid-flight rather than yielding a bad reading.
    static func parse(_ f: [UInt8]) -> Result? {
        var o = WireProtocol.headerSize
        guard let statusByte = Bytes.u8(f, o) else { return nil };  o += 1
        guard let count = Bytes.u8(f, o) else { return nil };       o += 1
        guard let home = Bytes.u8(f, o) else { return nil };        o += 1

        let status = Status.from(statusByte)

        let levelRoom = min(max(f.count - o, 0), WireProtocol.surveyChannelCount)
        let levels = (0..<min(Int(count), levelRoom)).compactMap { Bytes.i8(f, o + $0).map(Int.init) }
        o += WireProtocol.surveyChannelCount

        var confirmedChannels: [Int] = []
        var confirmedFrames: [Int] = []
        if o < f.count {
            guard let confirmedCount = Bytes.u8(f, o) else { return nil };  o += 1
            let room = min(max(f.count - o, 0), WireProtocol.surveyConfirmCount)
            let n = min(Int(confirmedCount), room)
            confirmedChannels = (0..<n).compactMap { Bytes.u8(f, o + $0).map(Int.init) }
            o += WireProtocol.surveyConfirmCount
            let frameRoom = min(max(f.count - o, 0), WireProtocol.surveyConfirmCount)
            confirmedFrames = (0..<min(n, frameRoom)).compactMap { Bytes.u8(f, o + $0).map(Int.init) }
        }

        return analyze(status: status, levels: levels, homeChannel: Int(home),
                       confirmedChannels: confirmedChannels, confirmedFrames: confirmedFrames)
    }
}
