import Foundation

/// Flight events the locator records per archived flight, in the wire order of
/// `FlightEventsMessage.event_timestamp_ms`.
///
/// MUST match the firmware's `Communication::FlightEvent` enum on **both** the
/// locator and the receiver (`kFlightEventCount == 11`), and the Android
/// `FlightEventIndex`. Order is the wire contract, not a display preference.
enum FlightEventIndex: Int, CaseIterable {
    case launch
    case burnout
    case apogee
    case noseover
    case droguePrimaryDeploy
    case drogueBackupDeploy
    case drogueVelocityThreshold
    case mainPrimaryDeploy
    case mainBackupDeploy
    case mainVelocityThreshold
    case landing

    var label: String {
        switch self {
        case .launch:                  return "Launch"
        case .burnout:                 return "Burnout"
        case .apogee:                  return "Apogee"
        case .noseover:                return "Noseover"
        case .droguePrimaryDeploy:     return "Drogue Primary"
        case .drogueBackupDeploy:      return "Drogue Backup"
        case .drogueVelocityThreshold: return "Drogue Deploy"
        case .mainPrimaryDeploy:       return "Main Primary"
        case .mainBackupDeploy:        return "Main Backup"
        case .mainVelocityThreshold:   return "Main Deploy"
        case .landing:                 return "Landing"
        }
    }
}
