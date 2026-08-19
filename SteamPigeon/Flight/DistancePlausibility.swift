import Foundation

/// ADR-0022: can the app stand behind this distance and bearing?
///
/// This withholds **derived figures**, never the position itself — the rocket marker
/// keeps rendering. What gets suppressed is a number the user would otherwise walk
/// toward, and the failure that prompted the ADR was a spoken callout of ~12 million
/// metres: a launch point captured with no GPS lock, sitting at 0,0, so the reading
/// was the great-circle distance to null island.
///
/// Every bound errs **loose on purpose**. Falsely rejecting a distance during a real
/// recovery takes away the number the user is walking toward, which is far worse than
/// showing one bad reading a moment longer.
struct DistancePlausibility {

    /// Several times practical LoRa range, and an order of magnitude below the
    /// observed failure, so it cannot fire on a real flight.
    static let maxRadioRangeM = 100_000

    /// Slack for GPS noise, so a stationary rocket is never judged to have jumped.
    static let positionNoiseMarginM = 100

    /// A 3D fix takes four satellites.
    static let minSatellitesForFix: UInt8 = 4

    /// Ceiling on **ground speed** by flight phase.
    ///
    /// One number for the whole flight had to be the boost number, which left it
    /// uselessly loose everywhere else — a rocket sitting in a field was allowed to
    /// have moved kilometres between reports.
    static func maxGroundSpeedMs(_ state: FlightStates) -> Double {
        if state == .launched || state == .burnout { return 400 }   // weathercocked boost
        if state.isAirborne { return 200 }                          // ballistic descent
        if state.isGrounded { return 5 }                            // carried back, plus drift
        // NoSignal, which is also what any unrecognized state byte decodes to. Be
        // permissive rather than blank a distance on a state we failed to understand.
        return 400
    }

    /// How far the rocket could have travelled during `elapsed` spent in `state`.
    static func phaseTravelM(_ state: FlightStates, elapsed: TimeInterval) -> Double {
        maxGroundSpeedMs(state) * max(0, elapsed)
    }

    // MARK: - State

    /// Distance at the last reading backed by a real fix.
    private var anchorDistanceM: Int?
    /// Travel budget accumulated since that anchor.
    private var budgetM: Double = 0
    private var lastUpdate: Date?

    init() {}

    /// Does the locator itself claim a usable fix?
    static func hasFix(satellites: UInt8, gpsStatus: SensorHealth) -> Bool {
        satellites >= minSatellitesForFix && gpsStatus == .ok
    }

    /// Judge one reading. Returns nil when the figure must be withheld.
    ///
    /// - A distance beyond radio range is rejected outright, **whatever the locator
    ///   claims about its own fix**.
    /// - A fixless reading is rejected on having *jumped*, not on being fixless: a
    ///   stale but believable distance is still shown.
    mutating func accept(distanceM: Int,
                         hasFix: Bool,
                         state: FlightStates,
                         now: Date = Date()) -> Int? {
        defer { lastUpdate = now }

        // 1. Outright range check, applied to every quoted distance.
        guard (0...Self.maxRadioRangeM).contains(distanceM) else { return nil }

        if hasFix {
            anchorDistanceM = distanceM
            budgetM = 0
            return distanceM
        }

        // 2. Integrate the allowance at the bound for the phase current at this step.
        //    A fixless stretch spans phases: lose the fix under canopy and be heard
        //    from next on the ground. Charging the whole gap at the ground bound reads
        //    2 km of real flight as a jump; charging it at the descent bound lets a
        //    rocket in a field cross a county.
        let elapsed = lastUpdate.map { now.timeIntervalSince($0) } ?? 0
        budgetM += Self.phaseTravelM(state, elapsed: elapsed)

        guard let anchor = anchorDistanceM else {
            // Never had a fix this session. Nothing to compare against, so the range
            // check above is the only judgement available — and it passed.
            return distanceM
        }

        let jump = abs(distanceM - anchor)
        let allowed = budgetM + Double(Self.positionNoiseMarginM)
        return Double(jump) <= allowed ? distanceM : nil
    }

    /// Forget the anchor — a new flight is not judged against the previous one.
    mutating func reset() {
        anchorDistanceM = nil
        budgetM = 0
        lastUpdate = nil
    }
}
