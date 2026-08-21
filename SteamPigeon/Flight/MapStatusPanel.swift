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

    // ── Actions ──────────────────────────────────────────────────────────────
    // The status rows are small on purpose, so rather than hunting for a fine tap
    // target the user taps ANYWHERE on the panel to drop down large buttons. It
    // auto-collapses after an idle period.
    var canArm: Bool = false
    var armPending: Bool = false
    var onRescan: (() -> Void)?
    var onToggleArmed: (() -> Void)?

    /// ADR-0021 pad alert, as the locator reports it. Drives the snooze control.
    var padAlert: PadAlertState = .quiet
    var padAlertSnoozeMinutes: Int = 0
    var onSnoozePadAlert: (() -> Void)?

    // Android's metrics, not approximations of them (FlightMapScreen.kt:2142-2146).
    // The name column is FIXED, not flexible: a flexible one grows into the icon
    // gutter as soon as a name is long, which is exactly the crowding this avoids.
    private let iconSize: CGFloat = 20
    private let iconGutter: CGFloat = 40      // wide enough for rocket icon + satellite count
    private let batteryGutter: CGFloat = 24

    /// Android's name column is a fixed 190 dp, which fits its 411 dp reference phone
    /// with the menu button and the controls column either side. On a 375 pt iPhone
    /// the same total overflows and pushes the controls off screen entirely, so the
    /// name column is a MAXIMUM here and shrinks first. It is the only part of the
    /// row that can give: the gutters are sized to their glyphs.
    private let maxNameWidth: CGFloat = 190

    /// Hoisted, so tapping the MAP can collapse it too — Android hoists this for the
    /// same reason. A dropdown that can only be dismissed by hitting the same small
    /// panel again is a trap on a screen where everything else is a map gesture.
    @Binding var actionsExpanded: Bool
    @State private var collapseTask: Task<Void, Never>?
    @State private var blinkOn = true

    /// Android: `actionPanelCollapseDelay`.
    private static let collapseDelay: Duration = .seconds(5)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            receiverRow
            locatorRow
            linkRow
            if let note = linkNote {
                Text(note.text)
                    .font(SPFont.bodySmall)
                    .foregroundStyle(note.color)
                    // Fixed width so a long verdict wraps instead of widening the
                    // panel — unconstrained it lays out on one line and drags the
                    // whole block wider whenever the verdict changes.
                    .frame(maxWidth: iconGutter + maxNameWidth + batteryGutter, alignment: .leading)
            }
            if actionsExpanded { actionButtons }
        }
        .padding(8)
        .background(SPColor.mapOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture { toggleActions() }
        .animation(.easeInOut(duration: 0.18), value: actionsExpanded)
    }

    private func toggleActions() {
        actionsExpanded.toggle()
        collapseTask?.cancel()
        guard actionsExpanded else { return }
        scheduleCollapse()
    }

    /// (Re)start the idle timer that tidies the dropdown away.
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(for: Self.collapseDelay)
            if !Task.isCancelled { actionsExpanded = false }
        }
    }

    /// A Material filled button: EXACTLY 48 pt tall, stadium-shaped, with the
    /// container/content colour pair from the scheme rather than a tint over white.
    /// Building it explicitly rather than styling `.borderedProminent`, whose padding
    /// added to the frame height and whose content colour is not `onPrimary`.
    private func actionButton(_ title: String,
                              container: Color,
                              content: Color,
                              enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(SPFont.labelLarge)
                .foregroundStyle(enabled ? content : content.opacity(0.5))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(enabled ? container : container.opacity(0.35))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Large, clearly labelled targets — this is pressed outdoors, often in a hurry.
    private var actionButtons: some View {
        VStack(spacing: 8) {
            actionButton("Rescan", container: SPColor.primary, content: SPColor.onPrimary) {
                actionsExpanded = false
                onRescan?()
            }

            // Snooze appears ONLY while the alert is actually sounding, so it cannot be
            // pressed pre-emptively to keep a rocket permanently quiet. It is the
            // operator saying "still prepping" (ADR-0021 Decision 5), and the locator
            // bounds it regardless of what the app asks for — a snooze that could be
            // made indefinite is an off switch, and hands back the forgotten arm this
            // exists to catch.
            if padAlert != .quiet {
                // Disabled at the ceiling rather than hidden, so "no more" is visible
                // instead of the control vanishing. And it does NOT collapse the panel:
                // tapping to accumulate should not cost a re-open each time.
                let atCeiling = padAlertSnoozeMinutes >= PadAlertState.snoozeCeilingMinutes
                actionButton(padAlert == .snoozed
                             ? "Snoozed \(padAlertSnoozeMinutes) min — add \(PadAlertState.snoozeStepMinutes)"
                             : "Snooze \(PadAlertState.snoozeStepMinutes) min",
                             container: SPColor.tertiary, content: SPColor.onTertiary,
                             enabled: !atCeiling) {
                    onSnoozePadAlert?()
                    // Restart the collapse timer rather than defeating it: tap as often
                    // as you like, and it still closes once you stop.
                    scheduleCollapse()
                }
            }

            // Disarm is error-coloured, as on Android: the consequences of the two
            // are not symmetric.
            actionButton(armed ? "Disarm" : "Arm",
                         container: armed ? SPColor.error : SPColor.primary,
                         content: armed ? SPColor.onError : SPColor.onPrimary,
                         enabled: canArm) {
                actionsExpanded = false
                onToggleArmed?()
            }
        }
        .frame(maxWidth: iconGutter + maxNameWidth + batteryGutter)
        .padding(.top, 8)
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
                .font(SPFont.bodyLarge)
                .foregroundStyle(SPColor.onBackground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxNameWidth, alignment: .leading)
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
                    // While a command is in flight the icon blinks toward its TARGET
                    // colour — green when arming, white when disarming — so the user
                    // sees the request was taken before the locator confirms.
                    .foregroundStyle(armPending
                                     ? (armed ? Color.white : Color.green)
                                     : rocketTint)
                    .opacity(armPending && !blinkOn ? 0.15 : 1)
                    .animation(armPending
                               ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                               : .default, value: blinkOn)
                    .onChange(of: armPending) { pending in blinkOn = !pending }
                if let s = satellites {
                    Text("\(s)")
                        .font(.custom("Poppins-Regular", size: 10, relativeTo: .caption2))
                        .baselineOffset(7)          // superscript, as Android sets
                        .foregroundStyle(rocketTint)
                }
            }
            .frame(width: iconGutter, alignment: .leading)

            Text(locatorText)
                .font(SPFont.bodyLarge)
                .foregroundStyle(SPColor.onBackground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxNameWidth, alignment: .leading)
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
                    .font(SPFont.bodyLarge)
                    .foregroundStyle(RssiBand.color(r))
            }
            if let s = snr {
                Text("SNR \(s) dB")
                    .font(SPFont.bodyLarge)
                    .foregroundStyle(SnrBand.color(s))
            }
        }
        .frame(maxWidth: iconGutter + maxNameWidth + batteryGutter, alignment: .leading)
    }

    /// Battery as a glyph alone. The voltage text is deliberately absent — that
    /// column is wanted for something else, and the glyph already carries the level.
    @ViewBuilder private func battery(_ mv: UInt16?) -> some View {
        if let mv, mv > 0 {
            let volts = Double(mv) / 1000
            Image(systemName: batterySymbol(volts))
                .font(.system(size: iconSize * 0.8))
                .foregroundStyle(volts < 3.5 ? SPColor.error : SPColor.onSurfaceVariant)
                .frame(width: batteryGutter, alignment: .leading)
                .accessibilityLabel(String(format: "Battery %.2f volts", volts))
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

    /// The device name alone. Armed state is carried by the rocket icon's tint, as on
    /// Android — spelling it out again in the row is a second claim to keep in sync.
    private var locatorText: String {
        guard let n = locatorName, !n.isEmpty else { return "No Locator" }
        return n
    }

    private var rocketTint: Color {
        guard let g = gpsStatus else { return SPColor.outline }
        return g == .ok ? SPColor.primary : SPColor.tertiary
    }
}
