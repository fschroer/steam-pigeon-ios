import Foundation

/// Link-quality reporting from the receiver (ADR-0019).
enum LinkQuality {

    enum Verdict: Equatable {
        /// Nothing to report, or not enough information yet.
        case normal
        /// Channel is occupied but our packets are still clean. Informational.
        case congested
        /// Loud packets arriving dirty: something is degrading the link. Actionable.
        case interference
    }

    /// The receiver reports this when it took no idle sample in the interval.
    ///
    /// **Must equal the firmware's `kNoiseFloorUnknown`, which is `INT16_MIN`.** The
    /// field is an `int16_t` on the wire, so it arrives as −32768. On Android this
    /// was compared against `Int.MIN_VALUE` and therefore never matched: "no sample"
    /// was read as a real −32768 dBm floor, the session baseline latched onto it, and
    /// every subsequent reading looked ~32000 dB elevated. A sentinel is a wire
    /// constant — pinned by `WireLayoutTests`.
    static let noiseFloorUnknown = Int(Int16.min)

    /// Above this the packet is arriving comfortably — roughly 30 dB above the
    /// SF7/BW125 sensitivity floor. Below it, poor SNR is adequately explained by
    /// distance and must not raise an alert.
    static let strongRssiDbm = -90

    /// A packet this loud should have SNR far above the −7.5 dB demod floor. Not
    /// reaching this margin while arriving strong means power in the channel that is
    /// not our signal.
    static let poorSnrDb = 3

    /// How far the idle floor must rise above the quietest floor seen this session
    /// before the channel counts as occupied. **Relative, not absolute:** SX126x RSSI
    /// near the noise floor is uncalibrated and varies unit to unit, so a hardcoded
    /// dBm threshold would mean different things on different hardware.
    static let elevatedFloorMarginDb = 12

    /// A floor at or above this is occupied on its own evidence, whatever the session
    /// baseline says.
    ///
    /// The relative test alone has a hole: it assumes the channel was quiet at some
    /// point this session. If it is already busy when the app starts — the normal case
    /// for someone investigating interference — the baseline absorbs the interferer
    /// and nothing ever looks elevated. That is the same failure as the receiver
    /// sampling only when packets arrive: **the mechanism defeated by the condition it
    /// detects.**
    static let busyFloorDbm = -100

    /// Gap since the previous accepted broadcast that means we missed at least one.
    static let lossyGap: TimeInterval = 2.0
    /// How long a loss keeps counting toward the verdict.
    static let lossMemory: TimeInterval = 10.0
    /// Beyond this a measurement describes a packet that is no longer arriving.
    static let staleMeasurement: TimeInterval = 3.0

    /// Classify the link, mirroring Android's `LinkQuality.classify`.
    ///
    /// The ADR-0019 framing was too narrow and its own final section says so:
    /// everything about measuring *power* is close to useless against another
    /// locator, because **LoRa capture is strong — co-channel interference displaces
    /// rather than corrupts.** The receiver locks the first preamble and decodes that
    /// packet cleanly; ours is never heard. Nothing fails a CRC, SNR is pristine, the
    /// floor often stays quiet. That is why `foreignLocator` outranks every
    /// RSSI-derived signal here: a foreign id is not evidence OF occupancy, it IS
    /// occupancy — decoded, identified, unambiguous.
    static func classify(rssi: Int,
                         snr: Int,
                         noiseFloor: Int,
                         quietestFloor: Int,
                         lossy: Bool = false,
                         foreignLocator: Bool = false,
                         packetFresh: Bool = true,
                         floorFresh: Bool = true,
                         absoluteFloorTrusted: Bool = true) -> Verdict {
        // "Loud but dirty" is a property of a packet that ARRIVED. Once it has aged
        // out there is no packet to describe, and re-asserting the last one's verdict
        // indefinitely is how a link that simply stopped got reported as jammed.
        let degraded = packetFresh && rssi > strongRssiDbm && snr < poorSnrDb

        let haveFloor = floorFresh && noiseFloor != noiseFloorUnknown
        let haveBaseline = quietestFloor != noiseFloorUnknown

        // Two independent ways to be occupied: risen materially above this session's
        // quietest reading, or loud enough that no baseline is needed to say so.
        let risen = haveFloor && haveBaseline
            && noiseFloor - quietestFloor >= elevatedFloorMarginDb
        let loud = haveFloor && absoluteFloorTrusted && noiseFloor >= busyFloorDbm
        let elevated = risen || loud || foreignLocator

        if degraded {
            // Reported whether or not the floor corroborates: a continuous interferer
            // raises the floor, but one transmitting in bursts can wreck packets while
            // the sampled floor still looks quiet, and that must not go unreported.
            return .interference
        }
        if elevated && lossy {
            // The co-channel case: another LoRa transmitter collides with our
            // broadcasts rather than degrading them, so survivors look perfect and
            // `degraded` never fires while the locator visibly drops out.
            //
            // The conjunction keeps it honest. Loss alone is ambiguous — a locator
            // switched off or walked out of range also produces gaps — but a locator
            // that went away does not raise the noise floor.
            return .interference
        }
        if elevated { return .congested }   // occupied, but we are winning
        return .normal
    }

    /// Running quietest-floor baseline. `sample` may be `noiseFloorUnknown`.
    static func updateQuietestFloor(current: Int, sample: Int) -> Int {
        if sample == noiseFloorUnknown { return current }
        if current == noiseFloorUnknown { return sample }
        return min(current, sample)
    }
}
