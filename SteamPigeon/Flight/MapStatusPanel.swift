import SwiftUI

/// The top status column, mirroring Android's `MapControlsColumn` status rows.
///
/// Three rows in a fixed layout: the **receiver** (radio icon, name or connection
/// state, battery), the **locator** (rocket icon, satellite count, name and armed
/// state, battery), and the **link** (signal icon, RSSI, SNR) — with the interference
/// verdict as prose beneath.
///
/// The icon gutters are fixed-width so the three rows align down the column even as
/// the values change width, which is the same reason the readouts are monospaced.
struct MapStatusPanel: View {
    let receiverName: String?
    let connectionState: TransportState
    let receiverBatteryMv: UInt16?

    let locatorName: String?
    let satellites: UInt8?
    let gpsStatus: SensorHealth?
    let armed: Bool
    let locatorBatteryMv: UInt16?

    let rssi: Int?
    let snr: Int?
    /// The ADR-0019 verdict, when there is one. Prose, not a column entry.
    let linkNote: (text: String, color: Color)?

    // Android's metrics, not approximations of them (FlightMapScreen.kt:2142-2146).
    // The name column is FIXED, not flexible: a flexible one grows into the icon
    // gutter as soon as a name is long, which is exactly the crowding this avoids.
    private let iconSize: CGFloat = 20
    private let iconGutter: CGFloat = 40      // wide enough for rocket icon + satellite count
    private let nameWidth: CGFloat = 190      // fits a 20-character device name at body size
    private let batteryGutter: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            receiverRow
            locatorRow
            linkRow
            if let note = linkNote {
                Text(note.text)
                    .font(SPFont.labelSmall)
                    .foregroundStyle(note.color)
                    // Fixed width so a long verdict wraps instead of widening the
                    // panel — unconstrained it lays out on one line and drags the
                    // whole block wider whenever the verdict changes.
                    .frame(width: 220, alignment: .leading)
            }
        }
        .padding(8)
        .background(SPColor.mapOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var receiverRow: some View {
        HStack(spacing: 4) {
            Image("radio")
                .renderingMode(.template)
                .resizable().scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .frame(width: iconGutter, alignment: .leading)
                .foregroundStyle(connectionState == .ready ? SPColor.primary : SPColor.outline)
            Text(receiverText)
                .font(SPFont.telemetry)
                .foregroundStyle(SPColor.onBackground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: nameWidth, alignment: .leading)
            battery(receiverBatteryMv)
        }
    }

    private var locatorRow: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                Image("rocket_md")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(rocketTint)
                if let s = satellites {
                    Text("\(s)").font(SPFont.labelSmall).foregroundStyle(rocketTint)
                }
            }
            .frame(width: iconGutter, alignment: .leading)

            Text(locatorText)
                .font(SPFont.telemetry)
                .foregroundStyle(armed ? SPColor.error : SPColor.onBackground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: nameWidth, alignment: .leading)
            battery(locatorBatteryMv)
        }
    }

    private var linkRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "cellularbars")
                .font(.system(size: iconSize * 0.8))
                .frame(width: iconGutter, alignment: .leading)
                .foregroundStyle(rssi.map { RssiBand.color($0) } ?? SPColor.outline)
            if let r = rssi {
                Text("\(r) dBm")
                    .font(SPFont.telemetry)
                    .foregroundStyle(RssiBand.color(r))
            }
            if let s = snr {
                Text("SNR \(s) dB")
                    .font(SPFont.telemetry)
                    .foregroundStyle(SnrBand.color(s))
            }
        }
        .frame(width: iconGutter + nameWidth + batteryGutter, alignment: .leading)
    }

    /// Battery as a filled glyph plus volts, mirroring Android's battery icon column.
    @ViewBuilder private func battery(_ mv: UInt16?) -> some View {
        if let mv, mv > 0 {
            let volts = Double(mv) / 1000
            HStack(spacing: 2) {
                Image(systemName: batterySymbol(volts))
                    .font(.system(size: iconSize * 0.8))
                    .foregroundStyle(volts < 3.5 ? SPColor.error : SPColor.onSurfaceVariant)
                Text(String(format: "%.2fV", volts))
                    .font(SPFont.labelSmall)
                    .foregroundStyle(SPColor.onSurfaceVariant)
            }
        }
    }

    /// Single-cell LiPo: ~4.2 V full, ~3.2 V empty.
    private func batterySymbol(_ v: Double) -> String {
        switch v {
        case 4.0...:   return "battery.100"
        case 3.8..<4.0: return "battery.75"
        case 3.6..<3.8: return "battery.50"
        case 3.4..<3.6: return "battery.25"
        default:        return "battery.0"
        }
    }

    private var receiverText: String {
        if let n = receiverName, !n.isEmpty { return n }
        switch connectionState {
        case .ready:          return "Connected"
        case .connected:      return "Resolving…"
        case .connecting:     return "Connecting…"
        case .scanning:       return "Scanning…"
        case .noDevicesFound: return "No receiver"
        case .poweredOff:     return "Bluetooth off"
        case .unauthorized:   return "No permission"
        case .unsupported:    return "Unsupported"
        case .disconnected:   return "Disconnected"
        case .idle:           return "Idle"
        }
    }

    private var locatorText: String {
        guard let n = locatorName, !n.isEmpty else { return "No Locator" }
        return armed ? "\(n) — ARMED" : n
    }

    private var rocketTint: Color {
        guard let g = gpsStatus else { return SPColor.outline }
        return g == .ok ? SPColor.primary : SPColor.tertiary
    }
}
