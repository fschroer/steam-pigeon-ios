import CoreMotion
import Foundation

/// How far the phone's heading can be trusted (ADR-0023).
///
/// Ordered so the **pessimistic** reading wins when sources disagree. That trade is
/// deliberately asymmetric: a missed warning costs someone walking a wrong bearing
/// through brush, a spurious one costs an unnecessary figure-eight.
enum CompassTrust: Int, Comparable {
    /// Nothing is obviously swamping the sensor.
    case high = 2
    /// Raise the calibration prompt. Advisory — does not take the bearing away.
    case low = 1
    /// Suppress the bearing, through the same gate ADR-0022 uses for an implausible
    /// position.
    case unreliable = 0

    static func < (a: CompassTrust, b: CompassTrust) -> Bool { a.rawValue < b.rawValue }
}

/// ADR-0023 §3b: ask the physics rather than the vendor.
///
/// On two of the three Android devices measured, **no vendor calibration flag was
/// usable at all** — a flag pinned at HIGH, or one that never fires, is
/// indistinguishable from a healthy compass. Total field strength is arithmetic
/// instead of a vendor's opinion, which is why it is the part of that ADR with unit
/// coverage, and why it ports cleanly to a platform whose flags are different again.
///
/// **This detects interference, not miscalibration.** A stale hard-iron offset rotates
/// the heading while leaving magnitude entirely plausible, so `high` means "nothing is
/// obviously swamping the sensor", never "the heading is right".
enum FieldMagnitude {

    /// The Earth's field runs about 22 µT (the South Atlantic minimum) to 67 µT (near
    /// the poles) anywhere on the surface; these are those bounds, slightly widened.
    static let earthMinUt: Double = 20
    static let earthMaxUt: Double = 70

    /// Beyond this the reading is not arguable. Measured: a magnet swept around a
    /// phone peaked at ~106 µT — detectable, but an order of magnitude below the
    /// "hundreds or thousands" originally assumed.
    static let grossMinUt: Double = 10
    static let grossMaxUt: Double = 100

    static func classify(magnitudeUt: Double) -> CompassTrust {
        if (earthMinUt...earthMaxUt).contains(magnitudeUt) { return .high }
        if magnitudeUt < grossMinUt || magnitudeUt > grossMaxUt { return .unreliable }
        // Outside the Earth's envelope but not by much: enough to raise the prompt,
        // not enough to take the bearing away.
        return .low
    }
}

/// ADR-0023 §3b on iOS: **the magnitude has to come from the CALIBRATED field.**
///
/// Android's source is `TYPE_MAGNETIC_FIELD`, which is the bias-corrected sensor — its
/// uncalibrated readings live behind a different constant entirely. The first iOS port
/// reached for `CMMotionManager.startMagnetometerUpdates`, whose `magneticField` is
/// **raw**: it carries the phone's own hard-iron offset, and on a MagSafe-era iPhone the
/// magnet array alone can hold the total above the 70 µT ceiling for the life of the
/// device. Reported from the phone on 2026-09-02 as an ∞ mark permanently red beside a
/// heading that was near-correct against a landmark — the ADR's envelope working
/// perfectly on a number that was never the Earth's field to begin with.
///
/// The calibrated equivalent is `CMDeviceMotion.magneticField`, which arrives only while
/// device motion runs a magnetic or true-north reference frame — see
/// `PhoneLocation.startAttitudeMonitor`, where that requirement is what decides the frame.
enum CalibratedField {

    /// This source's verdict, or **nil when it has nothing to say**.
    ///
    /// `.uncalibrated` is the nil case, and deliberately so: CoreMotion documents the
    /// field values as unusable in that state, and they arrive as zeros — which the
    /// magnitude bands would read as a gross reading and suppress the bearing for. That
    /// is the same false positive in a new place. ADR-0023's "a source that has never
    /// spoken contributes nothing" covers it exactly.
    ///
    /// Whether `.uncalibrated` should instead be a verdict in its own right — it is the
    /// closest thing iOS has to the vendor flags Decision 3 is written around — is the
    /// open question recorded in that ADR, not something to settle here.
    static func classify(_ field: CMCalibratedMagneticField) -> CompassTrust? {
        guard field.accuracy != .uncalibrated else { return nil }
        let f = field.field
        let magnitude = (f.x * f.x + f.y * f.y + f.z * f.z).squareRoot()
        return FieldMagnitude.classify(magnitudeUt: magnitude)
    }
}

/// Applies ADR-0023 §4: a degraded reading takes effect **immediately** and is held
/// for 3 s past the last bad reading. Only recovery waits.
///
/// The readings chatter across bands under a real magnet — measured at 30 ms on
/// Android, and the fused-sensor rate is not something an app can pin. The hold
/// bridges that chatter without ever delaying a warning.
struct CompassTrustHold {

    static let recoveryHold: TimeInterval = 3

    private var worstRecent: CompassTrust = .high
    private var lastBad: Date?

    init() {}

    /// Feed one verdict; get the effective trust level.
    mutating func update(_ reading: CompassTrust, now: Date = Date()) -> CompassTrust {
        if reading < .high {
            // Degradation is immediate — never wait to warn.
            worstRecent = min(worstRecent, reading)
            lastBad = now
            return worstRecent
        }
        guard let bad = lastBad else { return .high }
        if now.timeIntervalSince(bad) >= Self.recoveryHold {
            worstRecent = .high
            lastBad = nil
            return .high
        }
        return worstRecent      // still inside the hold
    }

    /// Combine sources worst-of. A source that has never reported contributes
    /// nothing rather than contributing `high`, so a silent sensor cannot outvote a
    /// live one — that silent-source-votes-healthy bug was reintroduced twice on
    /// different Android hardware.
    static func worstOf(_ sources: [CompassTrust?]) -> CompassTrust? {
        let live = sources.compactMap { $0 }
        return live.min()
    }
}
