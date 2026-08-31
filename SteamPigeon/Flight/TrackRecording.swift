import Foundation
import CoreLocation

/// One recorded fix. Mirrors Android's `PathPoint`, including the fields iOS does not
/// draw yet — altitude feeds the 3D curtain and the timestamp the one-second markers,
/// and persisting them now means the file does not have to change when those land.
struct TrackPoint: Equatable {
    let latitude: Double
    let longitude: Double
    let altitudeM: Float
    /// Wall clock, NOT a monotonic clock: the track is persisted and reloaded across
    /// process restarts, where a monotonic zero has moved.
    let timestampMs: Int64

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// `FlightStates.isGrounded` / `.isAirborne` already exist on `LocatorVector.swift` and
// match Android's, including that `noSignal` is deliberately NOT grounded: unknown state
// bytes decode to it, and calling that "on the ground" would make the next real packet
// look like a fresh launch and wipe the track of the flight still in the air.

/// When the recorded track starts, stops, and is thrown away.
///
/// Pure, and separate from `LinkViewModel`, because these rules decide whether the one
/// place the user is walking to gets drawn — and every one of them is a rule rather
/// than a rendering detail.
enum TrackRecording {

    /// Below this AGL the rocket counts as about to land whatever the descent rate.
    static let landingAltitudeThresholdM: Float = 30
    /// A descent rate at or under this is noise, or a rocket that is not descending.
    static let minDescentRateForPrediction: Float = 1
    /// How close to touchdown counts as imminent.
    static let landingLeadTimeSeconds: Float = 3

    /// Seconds until the ground at the current descent rate, or infinity when the rate
    /// is too small to divide by.
    static func timeToGroundSeconds(aglM: Float, descentRateMs: Float) -> Float {
        descentRateMs > minDescentRateForPrediction ? aglM / descentRateMs : .greatestFiniteMagnitude
    }

    static func landingImminent(aglM: Float, descentRateMs: Float) -> Bool {
        aglM < landingAltitudeThresholdM
            || timeToGroundSeconds(aglM: aglM, descentRateMs: descentRateMs) < landingLeadTimeSeconds
    }

    /// True when the state pair marks the start of a flight, and so the moment to clear
    /// the recorded track.
    ///
    /// ANY grounded → airborne transition, not the `waitingLaunch` → `launched` edge
    /// specifically. The narrower rule is not defeated by losing a packet or two — the
    /// locator reports `launched` for the whole boost — but it is defeated by losing
    /// that entire window, which is a bad-but-possible way for boost to go.
    static func startsNewFlight(previous: FlightStates, current: FlightStates) -> Bool {
        previous.isGrounded && current.isAirborne
    }

    /// True when the flight is over as far as this frame can tell.
    ///
    /// Two ways to know. The locator's own `landed` is the authority. Short of that,
    /// telemetry on the way down reaches the point where touchdown is a second or two
    /// away, and what arrives after that is a rocket settling in the grass and a fix
    /// wandering around it — which turns the end of the track into a scribble over the
    /// one place the user is trying to walk to.
    static func landingConcluded(state: FlightStates, aglM: Float, descentRateMs: Float) -> Bool {
        state == .landed
            || (state.rawValue > FlightStates.noseover.rawValue && state.isAirborne
                && landingImminent(aglM: aglM, descentRateMs: descentRateMs))
    }

    /// Whether an arriving fix joins the track.
    ///
    /// Both flags are the values from BEFORE this fix was examined, which is what lets
    /// the two fixes that end a flight be drawn rather than suppressed by the
    /// conclusion they themselves cause:
    ///
    /// - The fix the app infers the landing from is the lowest, last-known position,
    ///   and the most useful point on the whole track.
    /// - The first fix carrying `landed` is the locator's own account of where the
    ///   rocket is lying. It outranks anything the app inferred, so it draws even
    ///   though the track was already frozen.
    ///
    /// That `landed` fix is the end of it. The hours of fixes the locator goes on
    /// sending from a field are not flight, and nothing resumes recording for this
    /// flight but the next launch or a manual reset.
    ///
    /// Note the last arm: **nothing is recorded while waiting on the pad.** That is
    /// what keeps GPS noise from drawing a scribble before launch — not a
    /// minimum-separation filter, which Android's own dedup test warns against because
    /// it silently swallows the real slow movement of a descent under canopy.
    static func recordsPathPoint(state: FlightStates,
                                 landingConcluded: Bool,
                                 landedStatusReceived: Bool) -> Bool {
        if landedStatusReceived { return false }
        if state == .landed { return true }
        if landingConcluded { return false }
        return state.rawValue > FlightStates.waitingLaunch.rawValue
    }

    /// True when this fix merely repeats the last one.
    ///
    /// EXACT equality, and nothing looser.
    ///
    /// This carried Android's original rationale — ~5 Hz transmits against a ~1 Hz
    /// payload refresh, so four frames in five repeat a fix — and that was wrong on
    /// both platforms. **The locator transmits once per second**: a 20 Hz superloop
    /// whose `case 2` is the only branch reaching the radio. There is no 5x stream.
    ///
    /// The duplication this guards against is the same payload being handled more
    /// than once (on Android, a leaked packet collector; the shape is platform-
    /// specific, the guard is not). It also catches the genuine 1 Hz case where the
    /// GPS fix has not advanced between two transmits — the rarer one, since the test
    /// includes baro altitude and two independent frames rarely agree on it exactly.
    /// The job is to drop exactly those and nothing else.
    static func repeatsFix(_ last: TrackPoint?,
                           latitude: Double, longitude: Double, altitudeM: Float) -> Bool {
        guard let last else { return false }
        return last.latitude == latitude && last.longitude == longitude
            && last.altitudeM == altitudeM
    }
}

/// The per-flight bookkeeping behind the rules above.
struct TrackRecorder {
    /// False until a telemetry packet has actually been seen, so the `waitingLaunch`
    /// this is initialised to is never mistaken for an observed ground state. Without
    /// it, an app restarted mid-flight reads its first packet as a launch and erases
    /// the track of the flight it just rejoined.
    private var flightStateObserved = false
    private var previousState: FlightStates = .waitingLaunch
    private var landingConcludedThisFlight = false
    private var landedStatusReceived = false

    enum Outcome: Equatable {
        /// Clear the track first, then append.
        case newFlight(record: Bool)
        case record
        case skip
    }

    mutating func observe(state: FlightStates, aglM: Float, descentRateMs: Float) -> Outcome {
        var cleared = false
        if flightStateObserved, TrackRecording.startsNewFlight(previous: previousState, current: state) {
            cleared = true
            landingConcludedThisFlight = false
            landedStatusReceived = false
        }

        let records = TrackRecording.recordsPathPoint(
            state: state,
            landingConcluded: landingConcludedThisFlight,
            landedStatusReceived: landedStatusReceived)

        // Set from the fix itself — on receipt, not on it being drawn: a `landed` fix
        // the de-duplicator drops still ends the recording.
        if TrackRecording.landingConcluded(state: state, aglM: aglM, descentRateMs: descentRateMs) {
            landingConcludedThisFlight = true
        }
        if state == .landed { landedStatusReceived = true }

        previousState = state
        flightStateObserved = true

        if cleared { return .newFlight(record: records) }
        return records ? .record : .skip
    }

    /// Manual reset. Recording resumes even mid-descent or with the rocket already
    /// down: a cleared track that then refused to draw would look broken.
    mutating func reset() {
        landingConcludedThisFlight = false
        landedStatusReceived = false
    }
}
