import Foundation

/// Per-sensor health, as the locator reports it.
enum SensorHealth: UInt8 {
    case off = 0, initializing = 1, ok = 2, warning = 3, error = 4, stale = 5

    /// Unrecognized values resolve to `.stale`, matching Android — an unknown health
    /// value must not present as healthy.
    static func from(_ v: UInt8) -> SensorHealth { SensorHealth(rawValue: v) ?? .stale }
}

/// What a deployment channel is wired to do.
enum DeployMode: UInt8 {
    case droguePrimary = 0, drogueBackup = 1, mainPrimary = 2, mainBackup = 3, unused = 7

    static func from(_ v: UInt8) -> DeployMode { DeployMode(rawValue: v) ?? .unused }
}

/// Which body axis points at the sky (#36).
enum NoseAxis: UInt8 {
    case auto = 0, x = 1, y = 2, z = 3

    static func from(_ v: UInt8) -> NoseAxis { NoseAxis(rawValue: v) ?? .auto }
}

/// The locator's prepped-and-disarmed verdict (ADR-0021, #37).
///
/// `snoozed` is reported distinctly rather than folded into `quiet` on purpose: a
/// silenced locator that looks identical to a healthy one is the failure that ADR
/// started from.
enum PadAlertState {
    case quiet, alerting, snoozed

    /// Wire encoding: 0 quiet, 1 alerting, 2+n snoozed with n minutes left.
    ///
    /// Anything unrecognized resolves to `snoozed`, never `quiet` — a value this
    /// build cannot interpret must not present as "nothing wrong".
    static func from(_ v: UInt8) -> PadAlertState {
        switch v {
        case 0:  return .quiet
        case 1:  return .alerting
        default: return .snoozed
        }
    }

    static func snoozeMinutes(_ v: UInt8) -> Int { v >= 2 ? Int(v) - 2 : 0 }

    /// Ceiling the LOCATOR clamps total remaining snooze to. Mirrored here only so the
    /// control can show "no more" rather than vanishing; the locator enforces it.
    static let snoozeCeilingMinutes = 15
    /// Added per tap. The locator accumulates and clamps.
    static let snoozeStepMinutes = 5
}

/// Flight state machine, in wire order.
///
/// **`noSignal` is the fallback for any unrecognized state byte**, which matters
/// beyond tidiness: Android counts it as neither grounded nor airborne, because
/// treating it as grounded would erase an in-flight track when one odd byte arrives.
enum FlightStates: UInt8, CaseIterable {
    case waitingLaunch = 0
    case launched = 1
    case burnout = 2
    case noseover = 3
    case droguePrimaryEvent = 4
    case drogueBackupEvent = 5
    case mainPrimaryEvent = 6
    case mainBackupEvent = 7
    case landed = 8
    case noSignal = 9

    static func from(_ v: UInt8) -> FlightStates { FlightStates(rawValue: v) ?? .noSignal }

    /// How the stats panel writes the state — **not** the case name.
    ///
    /// The general rule in this port is that Android renders `enumValue.name`, so a
    /// label is the case name (`DroguePrimary`, not "Drogue Primary"). The flight
    /// state is the exception: `LocatorStats` maps every state to display text by
    /// hand, and those are the words below. Reading the rule instead of the code put
    /// `droguePrimaryEvent` on screen.
    ///
    /// `noSignal` renders as **nothing**, matching Android's `else -> ""`. It is not a
    /// state the locator reports — it is this app's own fallback for a state byte it
    /// does not recognise — and naming it on the panel would tell the user the rocket
    /// is in a condition the rocket never claimed.
    var panelLabel: String {
        switch self {
        case .waitingLaunch:      return "Waiting For Launch"
        case .launched:           return "Launched"
        case .burnout:            return "Burnout"
        case .noseover:           return "Noseover"
        case .droguePrimaryEvent: return "Drogue Primary"
        case .drogueBackupEvent:  return "Drogue Backup"
        case .mainPrimaryEvent:   return "Main Primary"
        case .mainBackupEvent:    return "Main Backup"
        case .landed:             return "Landed"
        case .noSignal:           return ""
        }
    }
}
