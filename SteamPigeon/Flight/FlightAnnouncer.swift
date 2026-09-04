import Foundation

/// The flight callouts, ported from Android's `FlightSpeechAnnouncer`
/// (`FlightMapScreen.kt`): apogee, the deployment charges and their physical detections,
/// ascent altitudes, descent warnings, landing, and the link and GPS health lines.
///
/// **Pure, and for the usual reason** — same shape as `ChannelMoveRunner` and
/// `FlightLogRecorder`. It holds no clock, no timer and no speech engine: it takes a
/// sample and returns the lines to say. Everything here that is worth getting right is a
/// rule about *when to stay quiet*, and those are the rules that cannot be checked by
/// listening to a simulator that has no locator.
///
/// Android splits this across two effects that share their guard flags — one keyed on the
/// flight state, one a 500 ms poll keyed on `inFlight`. The same split is kept here as two
/// entry points over one set of guards, because the sharing is load-bearing: the poll loop
/// reads `landingSpoken` and `flightConcluded`, which the state-change path writes.
struct FlightAnnouncer {

    // MARK: - Android's constants, unchanged

    /// Below this the rocket is close enough to the ground to call it down.
    static let landingAltitudeThresholdM: Float = 30
    /// An ascent callout is only worth making while the rocket is still moving.
    static let minimumSpokenAglVelocityMs: Float = 2 * 9.8
    /// Poll cadence for the continuous callouts. Driven from a fixed interval rather than
    /// the speech engine's "is it speaking" flag, so the rate is the same on every phone.
    static let announcementInterval: TimeInterval = 0.5
    /// Minimum gap between descent warnings.
    static let descentWarningInterval: TimeInterval = 10
    /// Downward m/s that still counts as freefall — i.e. no canopy yet.
    static let freefallDescentRateMs: Float = 50
    /// Floor for the time-to-ground division: a rate near zero is noise or a rocket that
    /// is not descending, not a landing about to happen.
    static let minDescentRateForPredictionMs: Float = 1
    /// How long before predicted touchdown the landing is announced.
    static let landingLeadTime: Float = 3
    /// Telemetry gap called out as a lost link.
    static let linkLossTimeout: TimeInterval = 3
    /// Telemetry gap during descent that triggers the dead-reckoned landing.
    static let landingLinkLossTimeout: TimeInterval = 5

    // MARK: - Landing prediction

    /// Seconds until the rocket reaches the ground at its current descent rate, or
    /// `.greatestFiniteMagnitude` when the rate is too small to divide by.
    static func timeToGroundSeconds(aglM: Float, descentRateMs: Float) -> Float {
        descentRateMs > minDescentRateForPredictionMs
            ? aglM / descentRateMs
            : .greatestFiniteMagnitude
    }

    /// True when the rocket is about to touch down according to live telemetry.
    static func landingImminent(aglM: Float, descentRateMs: Float) -> Bool {
        aglM < landingAltitudeThresholdM
            || timeToGroundSeconds(aglM: aglM, descentRateMs: descentRateMs) < landingLeadTime
    }

    /// True when the rocket must be on the ground despite nothing having been heard from it.
    ///
    /// The link almost always dies before the landing does — the last few hundred metres
    /// are where line of sight across a field runs out — so a callout that waits to *hear*
    /// the touchdown mostly never comes. This flies the rocket the rest of the way down on
    /// the last altitude and descent rate it managed to send. The 5 s floor keeps a routine
    /// dropout from concluding a flight, which is not a decision that can be taken back.
    static func landedThroughBlackout(aglM: Float, descentRateMs: Float,
                                      messageAge: TimeInterval) -> Bool {
        messageAge >= landingLinkLossTimeout
            && (landingImminent(aglM: aglM, descentRateMs: descentRateMs)
                || Float(messageAge) >= timeToGroundSeconds(aglM: aglM, descentRateMs: descentRateMs))
    }

    // MARK: - What the announcer is told, and what it says

    /// One reading of everything the callouts depend on.
    ///
    /// Defaults on every field so a test can state only what it is about.
    struct Sample {
        /// Android's `isInFlight`: armed, or a flight state other than WaitingLaunch.
        var inFlight = false
        var flightState: FlightStates = .waitingLaunch
        var altitudeAglM: Float = 0
        /// NED **down** component: positive while descending.
        var descentRateMs: Float = 0
        /// Total speed from the NED vector, as Android's `state.velocity`.
        var velocityMs: Float = 0
        var gpsOk = false
        /// How long since the last broadcast from the locator.
        var messageAge: TimeInterval = 0
        /// The locator's position, or nil when it is not a fix worth using. A launch point
        /// captured with no GPS lock sits on null island, and the distance to it is the
        /// ~12 000 km Android used to read out as a recovery bearing.
        var position: (lat: Double, lon: Double)?
        var drogueDeployDetected = false
        var mainDeployDetected = false
        /// Per deployment channel, in channel order.
        var channelModes: [DeployMode] = []
        var channelFired: [Bool] = []
    }

    /// A line to speak, and whether it waits its turn.
    struct Line: Equatable {
        let text: String
        let priority: FlightSpeech.Priority

        /// Android's `announcer.add` — `QUEUE_ADD`.
        static func routine(_ text: String) -> Line { Line(text: text, priority: .routine) }
        /// Android's `announcer.flush` — `QUEUE_FLUSH`, cutting in.
        static func urgent(_ text: String) -> Line { Line(text: text, priority: .urgent) }
    }

    // MARK: - Guards shared by both entry points

    private var previousAGL = 0
    private var apogeeSpoken = false
    private var launchedState = false
    /// One entry per charge already announced, replacing four booleans.
    ///
    /// **The flight state is a floor, not a trigger**, and the booleans got that
    /// wrong on both platforms. `flight_state_` is monotonic in the locator
    /// (`AdvanceFlightState` only moves forward) and the four deployment blocks are
    /// latched *independently* — issue #10, which the firmware states outright: a
    /// drogue backup "must still fire after its delay even if a main event has
    /// already advanced flight_state_ past it". So a charge can fire seconds after
    /// the state gating its callout has gone by.
    ///
    /// Bench case: ch1 DrogueBackup on a 1.0 s delay with an e-match fitted, ch2
    /// MainPrimary at 130 m with none, noseover at 110 m. Main's condition is
    /// `agl <= 130` — a test, not a downward crossing — so it is true at apogee:
    /// ch2 is commanded at once and the state jumps to `mainPrimaryEvent`, past
    /// `drogueBackupEvent` entirely. The drogue fires a second later. Latching on
    /// the state meant the drogue callout was evaluated at apogee, found the
    /// channel not yet fired, latched, and never looked again — announcing the
    /// charge that did nothing and staying silent on the one that fired. It was
    /// also a race: at 1 Hz a broadcast landing after the delay would have caught
    /// it, so the callout came and went between flights.
    ///
    /// Latching on the **announcement** leaves each pending until its charge
    /// actually fires. A charge that never fires is never announced.
    private var spokenCharges: Set<DeployMode> = []
    private var drogueDeploySpoken = false
    private var mainDeploySpoken = false
    private var landingSpoken = false
    /// Set once the rocket is down — reported landed, or dead-reckoned to the ground
    /// during a blackout. Everything the locator has to say after that point is history:
    /// the events it flew through while out of contact arrive in a burst the moment the
    /// link returns, and announcing "main charge" over a rocket already lying in a field is
    /// worse than saying nothing.
    private var flightConcluded = false
    private var receivedState: FlightStates = .waitingLaunch
    /// Android keeps a timestamp here and only ever tests it for zero.
    private var noseoverSeen = false
    private var launchLocation: (lat: Double, lon: Double)?

    // MARK: - Guards owned by the poll loop

    // Android declares these inside `LaunchedEffect(inFlight)`, so they are reset every
    // time that loop restarts and NOT by the landing reset. `pollingStarted()` is that
    // restart.
    private var lastDescentWarning: Date?
    private var linkEverLive = false
    private var linkLostSpoken = false
    private var gpsOkLast: Bool?

    init() {}

    // MARK: - Discrete flight-state transitions

    /// Android's `LaunchedEffect(rocketState.flightState)`.
    mutating func flightStateChanged(_ s: Sample) -> [Line] {
        guard s.inFlight, s.flightState.rawValue > receivedState.rawValue else { return [] }
        receivedState = s.flightState
        var lines: [Line] = []

        // The locator's own landing detection ends the flight, and it is the authority on
        // the matter. Handled FIRST, ahead of the per-event checks: a link that comes back
        // after the rocket is already down delivers the whole flight in one step, and
        // running those checks on it read out every charge it flew through minutes earlier.
        if s.flightState.rawValue >= FlightStates.landed.rawValue {
            // Still worth saying once, if the blackout reckoning has not already — this is
            // the number the user walks toward.
            if !landingSpoken {
                lines.append(.urgent("Landing" + (launchRelativePhrase(s) ?? ", location unknown.")))
            }
            resetForNextFlight()
            return lines
        }

        // Landing was already presumed from the last telemetry before the link dropped, so
        // anything arriving now describes a rocket that is on the ground. Stay quiet until
        // the locator confirms Landed above.
        if flightConcluded { return lines }

        if s.flightState.rawValue >= FlightStates.launched.rawValue, !launchedState {
            launchedState = true
            launchLocation = s.position
        }
        if s.flightState.rawValue >= FlightStates.noseover.rawValue, !noseoverSeen {
            noseoverSeen = true
            if !apogeeSpoken {
                apogeeSpoken = true
                lines.append(.routine("Apogee, \(Int(s.altitudeAglM)) meters."))
            }
        }
        // Each stays pending until its charge actually fires, so one that fires
        // after the flight state has moved past it is still announced. Ladder
        // order, so two charges landing in one sample come out in the order the
        // locator walked them.
        for step in Self.chargeLadder {
            guard !spokenCharges.contains(step.mode),
                  s.flightState.rawValue >= step.floor.rawValue,
                  fired(step.mode, s)
            else { continue }
            spokenCharges.insert(step.mode)
            lines.append(.routine(step.phrase))
        }
        return lines
    }

    // MARK: - The 500 ms poll

    /// Android restarts `LaunchedEffect(inFlight)` whenever the flight begins, which
    /// re-declares the four guards below. Call this when polling starts.
    mutating func pollingStarted() {
        lastDescentWarning = nil
        linkEverLive = false
        linkLostSpoken = false
        gpsOkLast = nil
    }

    /// One tick of Android's poll loop.
    mutating func poll(_ s: Sample, now: Date = Date()) -> [Line] {
        guard s.inFlight else { return [] }
        var lines: [Line] = []

        let linkLive = s.messageAge < Self.linkLossTimeout
        let fromLaunch = launchRelativePhrase(s)

        // Link health. Edge-triggered, and announced only after the link has been live at
        // least once — starting the app out of range is silence rather than a report of
        // something that was never there.
        if linkLive {
            linkEverLive = true
            if linkLostSpoken {
                linkLostSpoken = false
                lines.append(.routine("Telemetry restored."))
            }
        } else if linkEverLive, !linkLostSpoken {
            linkLostSpoken = true
            // In the air the last known position is the part worth hearing; on the pad or
            // after landing it is just the number already on screen.
            let airborne = s.flightState.rawValue > FlightStates.waitingLaunch.rawValue
                && s.flightState.rawValue < FlightStates.landed.rawValue
            if airborne, let fromLaunch {
                lines.append(.urgent("Telemetry lost. Last known\(fromLaunch)"))
            } else {
                lines.append(.urgent("Telemetry lost."))
            }
        }

        // GPS health, reported only while the link is live: with no messages arriving the
        // locator's last-sent status is stale and says nothing about whether it has a fix.
        if linkLive {
            if let last = gpsOkLast, s.gpsOk != last {
                lines.append(.routine(s.gpsOk ? "GPS fix restored." : "GPS fix lost."))
            }
            gpsOkLast = s.gpsOk
        }

        // Ascent altitude callouts every 100 m during coast to apogee.
        if s.flightState == .burnout {
            let rounded = Int(s.altitudeAglM / 100) * 100
            if rounded > previousAGL {
                if s.velocityMs > Self.minimumSpokenAglVelocityMs {
                    lines.append(.routine("\(rounded) meters."))
                }
                previousAGL = rounded
            }
        }

        // Descent: periodic warnings while in freefall, then exactly one landing.
        if s.flightState.rawValue > FlightStates.noseover.rawValue,
           s.flightState.isAirborne, !landingSpoken {
            let agl = s.altitudeAglM
            if Self.landedThroughBlackout(aglM: agl, descentRateMs: s.descentRateMs,
                                          messageAge: s.messageAge) {
                landingSpoken = true
                flightConcluded = true
                lines.append(.urgent("Landing." + (fromLaunch.map { " Last known\($0)" }
                                                   ?? " Location unknown.")))
            } else if !linkLive {
                // Everything below needs a live link: altitude and descent rate out of a
                // stale packet describe where the rocket was, not where it is.
            } else if Self.landingImminent(aglM: agl, descentRateMs: s.descentRateMs) {
                landingSpoken = true
                flightConcluded = true
                lines.append(.urgent("Landing" + (fromLaunch ?? ", location unknown.")))
            } else if s.descentRateMs >= Self.freefallDescentRateMs,
                      now.timeIntervalSince(lastDescentWarning ?? .distantPast)
                        >= Self.descentWarningInterval {
                lastDescentWarning = now
                lines.append(.urgent("Descent warning, \(Int(s.descentRateMs)) meters per second"
                                     + (fromLaunch ?? "")))
            }
        }

        // Physical deployment detections. Suppressed once the rocket is down: these flags
        // arrive latched, so the first packet after a blackout that outlasted the flight
        // would otherwise report a deployment on the way to a landing already announced.
        //
        // `isAirborne` is load-bearing, not belt-and-braces. On reaching Landed the
        // state-change path resets every guard for the next flight — including
        // `flightConcluded` and both deploy flags — while this loop is still polling the
        // same Landed telemetry, whose deploy bits are still latched true. Without the
        // airborne test the next tick re-announces both, having just been told it never had.
        if !flightConcluded, s.flightState.isAirborne {
            if s.flightState.rawValue >= FlightStates.droguePrimaryEvent.rawValue,
               !drogueDeploySpoken, s.drogueDeployDetected {
                drogueDeploySpoken = true
                lines.append(.routine("Drogue deployed."))
            }
            if s.flightState.rawValue >= FlightStates.mainPrimaryEvent.rawValue,
               !mainDeploySpoken, s.mainDeployDetected {
                mainDeploySpoken = true
                drogueDeploySpoken = true
                lines.append(.routine("Main deployed."))
            }
        }
        return lines
    }

    // MARK: - Helpers

    /// " N meters <ordinal> of launch point.", or nil when there is no such claim to make.
    ///
    /// **ADR-0022's range ceiling is checked here too**, not only on the displayed figure:
    /// an impossible distance read aloud as a recovery bearing is worse than the same
    /// number sitting in a corner of the screen, because it is instruction rather than
    /// readout. Callers word the no-position case themselves.
    private func launchRelativePhrase(_ s: Sample) -> String? {
        guard s.gpsOk, let launch = launchLocation, let now = s.position else { return nil }
        let vector = LocatorVector.between(from: launch, to: now)
        guard (0...DistancePlausibility.maxRadioRangeM).contains(vector.distanceM) else { return nil }
        return " \(vector.distanceM) meters \(vector.ordinal) of launch point."
    }

    /// Whether a channel wired for `mode` has fired.
    ///
    /// **Every channel, where Android tests only channels 1 and 2.** Its config carries
    /// four (`deploymentChannel1Mode`…`4Mode`) and its default wiring puts MainPrimary on
    /// channel 3 — so on Android the "Main charge." callout is unreachable with the stock
    /// configuration. Read as a defect there rather than a rule to port; recorded in
    /// `docs/UI_PARITY.md` under what Android owes.
    private func fired(_ mode: DeployMode, _ s: Sample) -> Bool {
        zip(s.channelModes, s.channelFired).contains { $0 == mode && $1 }
    }

    /// The ladder, in the order the locator walks it, each floored by the flight
    /// state that can first produce it. See `spokenCharges` for why the floor is
    /// not the trigger.
    private static let chargeLadder:
        [(mode: DeployMode, floor: FlightStates, phrase: String)] = [
        (.droguePrimary, .droguePrimaryEvent, "Drogue charge."),
        (.drogueBackup, .drogueBackupEvent, "Drogue backup charge."),
        (.mainPrimary, .mainPrimaryEvent, "Main charge."),
        (.mainBackup, .mainBackupEvent, "Main backup charge."),
    ]

    /// Android's landing branch resets exactly these, and not the poll loop's own guards.
    private mutating func resetForNextFlight() {
        previousAGL = 0
        launchedState = false
        apogeeSpoken = false
        spokenCharges.removeAll()
        drogueDeploySpoken = false
        mainDeploySpoken = false
        landingSpoken = false
        flightConcluded = false
        receivedState = .waitingLaunch
        noseoverSeen = false
        launchLocation = nil
    }
}
