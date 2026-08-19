import SwiftUI

extension SPColor {
    /// Translucent panel behind map overlays. Android: `mapOverlayBg = 0xC05D6F96`
    /// — 0xC0 alpha over 0x5D6F96.
    static let mapOverlay = Color(.sRGB,
                                  red: 0x5D / 255, green: 0x6F / 255, blue: 0x96 / 255,
                                  opacity: Double(0xC0) / 255)
}

/// RSSI band colours, mirroring Android's `rssiColor`.
enum RssiBand {
    static func color(_ rssi: Int) -> Color {
        if rssi >= -80  { return Color(hex: 0x4CAF50) }   // green  — excellent
        if rssi >= -100 { return Color(hex: 0xFFC107) }   // amber  — good
        if rssi >= -110 { return Color(hex: 0xFF9800) }   // orange — fair
        return Color(hex: 0xF44336)                       // red    — poor
    }
}

/// SNR band colours, mirroring Android's `snrColor`.
///
/// How much room is left above the SF7 demodulator floor (about −7.5 dB) — how close
/// the link is to dropping packets, whatever the cause.
///
/// **Deliberately not the interference rule.** Low SNR at range is normal and expected
/// near apogee, so this reads as "margin is thinning", not "something is wrong".
/// Whether the cause is distance or another emitter is the separate, quieter verdict
/// under this row, which stays silent unless the signal is *also* strong (ADR-0019).
/// Colouring SNR by the interference rule would put the apogee false alarm back in, as
/// colour instead of text.
enum SnrBand {
    static func color(_ snr: Int) -> Color {
        if snr >= 5  { return Color(hex: 0x4CAF50) }      // green  — wide margin
        if snr >= 0  { return Color(hex: 0xFFC107) }      // amber  — comfortable
        if snr >= -5 { return Color(hex: 0xFF9800) }      // orange — thinning
        return Color(hex: 0xF44336)                       // red    — near the demod floor
    }
}

/// Per-channel deployment configuration text, mirroring Android's `deployChannelText`.
///
/// The delays arrive as tenths of a second and are printed as `N.N s`; the altitudes
/// are whole metres. Column-aligned by padding the mode names to equal width, which is
/// why "Main   Prm" carries the extra spaces.
enum DeployChannelText {
    static func line(channel: Int, mode: DeployMode, config: PreLaunchData) -> String {
        let abbr: String
        let value: String
        switch mode {
        case .droguePrimary:
            abbr = "Drogue Prm "
            value = " \(config.droguePrimaryDelay / 10).\(config.droguePrimaryDelay % 10) s"
        case .drogueBackup:
            abbr = "Drogue Bkp "
            value = " \(config.drogueBackupDelay / 10).\(config.drogueBackupDelay % 10) s"
        case .mainPrimary:
            abbr = "Main   Prm "
            value = " \(config.mainPrimaryAltitude) m"
        case .mainBackup:
            abbr = "Main   Bkp "
            value = " \(config.mainBackupAltitude) m"
        case .unused:
            abbr = "Unused"
            value = ""
        }
        return "Ch \(channel): \(abbr)\(value)"
    }
}
