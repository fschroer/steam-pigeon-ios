import SwiftUI
import UIKit

/// How much the drawn rocket position can be trusted, mirroring Android's
/// `RocketMarkerState`. Drives the marker and its accuracy ring together.
enum RocketMarkerState {
    /// Recent packet and the locator reports healthy GPS — the position is live.
    case live
    /// Recent packet, but GPS health other than Ok: the position it is sending is
    /// latched or degraded, not a current fix.
    case degraded
    /// No recent packet. Whatever is drawn is however old the last one was.
    case stale

    /// Android's constants, not approximations: 0xFF00FF00 / 0xFF9E9E9E / 0xFFFF0000.
    var color: UIColor {
        switch self {
        case .live:     return UIColor(red: 0, green: 1, blue: 0, alpha: 1)
        case .degraded: return UIColor(red: 0x9E/255.0, green: 0x9E/255.0, blue: 0x9E/255.0, alpha: 1)
        case .stale:    return UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        }
    }

    /// A packet older than this makes the position stale. Android: `messageTimeout`.
    static let messageTimeout: TimeInterval = 2.0

    /// **Link age is checked first.** If we are not hearing from the locator, its
    /// last-reported `gpsStatus` is itself stale and cannot qualify anything; only
    /// with a live link does a non-Ok status mean what it says.
    static func from(lastMessageAge: TimeInterval, gpsStatus: SensorHealth?) -> RocketMarkerState {
        if lastMessageAge >= messageTimeout { return .stale }
        return gpsStatus == .ok ? .live : .degraded
    }
}
