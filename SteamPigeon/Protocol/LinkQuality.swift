import Foundation

/// Link-quality reporting from the receiver (ADR-0019).
enum LinkQuality {

    enum Verdict {
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
}
