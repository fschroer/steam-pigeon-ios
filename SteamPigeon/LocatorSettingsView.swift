import SwiftUI

/// Locator Settings — deployment channels, name, mounting axis.
///
/// **This screen configures pyro channels.** Every value here decides when a charge
/// fires, which is why the primary/backup limits below are interlocked rather than
/// merely validated: a backup that fires before its primary is not a backup.
///
/// Edits are STAGED. The Update button sends the whole settings struct — that is the
/// wire format — and then reports what the locator said. A change that silently did
/// nothing is indistinguishable from one that never arrived.
struct LocatorSettingsView: View {
    @ObservedObject var model: LinkViewModel

    @State private var staged = LocatorConfig()
    @State private var edited = false

    private var busy: Bool { model.locatorConfigMessageState != .idle }

    var body: some View {
        // A scrolling column with the Update row pinned below it, as Android lays this
        // out — not a grouped Form. The grouped style is what made every value read as
        // a list entry rather than as a field.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // ORDER IS ANDROID'S, and it is not the order a form would suggest.
                    // The four deployment channels come FIRST, immediately under the
                    // firmware line, and the identity fields — name and mounting axis —
                    // come last. That reads oddly until you notice what the
                    // screen is for: the channels are what changes between flights, and
                    // the rest is set once per installation.
                    if let version = model.versionInfo, !version.locatorVersion.isEmpty {
                        Text("Firmware: \(version.locatorVersion)")
                            .font(SPFont.bodyMedium)
                            .foregroundStyle(SPColor.onSurfaceVariant)
                    }

                    ForEach(0..<4, id: \.self) { channel in
                        // A plain caption above a bare dropdown, as Android has it —
                        // its `EnumDropdown` passes no `label`, so the section name IS
                        // the field's name. There is no "Mode" label anywhere on that
                        // screen.
                        Text("Deployment Channel \(channel + 1)")
                            .font(SPFont.bodyLarge)
                            .padding(.top, 4)
                        ConfigPickerRow(selection: modeBinding(channel),
                                        options: DeployMode.allCasesInOrder,
                                        label: { $0.label },
                                        enabled: !busy)
                        // Only the field belonging to the SELECTED mode is shown, as
                        // Android does — a delay box under a channel set to Main is a
                        // value with nothing to apply to.
                        modeDetail(for: mode(channel))
                    }

                    ConfigTextRow(title: "Locator Name",
                                  text: Binding(get: { staged.deviceName },
                                                set: { staged.deviceName = $0; edited = true }),
                                  enabled: !busy)

                    // The LoRa channel moved to the Communication screen (ADR-0029),
                    // next to the two scans that choose one and the receiver channel
                    // that has to follow it. This screen is flight configuration; which
                    // frequency you are talking on is a different job, and doing it here
                    // meant deciding a channel on one screen and verifying it on another.
                    //
                    // **The field is gone, not the value:** `loraChannel` still rides in
                    // this screen's config struct, read back from the broadcast, so an
                    // edit to any other setting sends the locator's current channel
                    // unchanged.

                    // Static per installation, but the locator cannot infer it: mounting
                    // calibration finds the axis gravity lies along and calls it "up",
                    // which is only the nose axis if the rocket happens to be vertical.
                    // Stating it is what makes tilt-from-vertical measurable off the pad
                    // (ADR-0021 Decision 6).
                    Text("Sensor Axis Along Rocket")
                        .font(SPFont.bodyLarge)
                        .padding(.top, 4)
                    ConfigPickerRow(selection: Binding(get: { staged.noseAxis },
                                                       set: { staged.noseAxis = $0; edited = true }),
                                    options: NoseAxis.allCasesInOrder,
                                    label: { $0.label },
                                    enabled: !busy)
                }
                .padding(16)
            }

            Divider()
            Button(model.locatorConfigMessageState.buttonLabel) {
                model.changeLocatorConfig(staged)
                edited = false
            }
            .buttonStyle(.materialFilled)
            .disabled(!edited || busy)
            .padding(16)
        }
        .background(SPColor.background)
        .navigationTitle("Locator Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.remoteLocatorConfig) { latest in
            if !edited { staged = latest }
        }
        .onAppear { staged = model.remoteLocatorConfig }
    }

    // MARK: - Bindings

    private func mode(_ channel: Int) -> DeployMode {
        staged.deployChannelModes.indices.contains(channel)
            ? staged.deployChannelModes[channel] : .unused
    }

    private func modeBinding(_ channel: Int) -> Binding<DeployMode> {
        Binding(get: { mode(channel) },
                set: { newMode in
                    var modes = staged.deployChannelModes
                    while modes.count < 4 { modes.append(.unused) }
                    modes[channel] = newMode
                    staged.deployChannelModes = modes
                    edited = true
                })
    }

    /// The one numeric field the selected mode needs.
    ///
    /// **The limits are interlocked, not independent.** A drogue backup must fire AFTER
    /// its primary and a main backup BELOW its primary, so each bound is derived from
    /// the other value rather than from a constant. Android derives them the same way,
    /// and it is the only thing stopping a backup being configured to fire first.
    @ViewBuilder private func modeDetail(for mode: DeployMode) -> some View {
        switch mode {
        case .droguePrimary:
            ConfigDecimalRow(title: "Drogue Primary Deploy Delay (s)",
                             tenths: intBinding(\.droguePrimaryDelay),
                             range: 0...max(Int(staged.drogueBackupDelay) - 1, 0),
                             enabled: !busy)
        case .drogueBackup:
            ConfigDecimalRow(title: "Drogue Backup Deploy Delay (s)",
                             tenths: intBinding(\.drogueBackupDelay),
                             range: min(Int(staged.droguePrimaryDelay) + 1, 30)...30,
                             enabled: !busy)
        case .mainPrimary:
            ConfigIntRow(title: "Main Primary Deploy Altitude (m)",
                         value: int16Binding(\.mainPrimaryAltitude),
                         range: min(Int(staged.mainBackupAltitude) + 1, 500)...500,
                         enabled: !busy)
        case .mainBackup:
            ConfigIntRow(title: "Main Backup Deploy Altitude (m)",
                         value: int16Binding(\.mainBackupAltitude),
                         range: 0...max(Int(staged.mainPrimaryAltitude) - 1, 0),
                         enabled: !busy)
        case .unused:
            EmptyView()
        }
    }

    private func intBinding(_ path: WritableKeyPath<LocatorConfig, UInt8>) -> Binding<Int> {
        Binding(get: { Int(staged[keyPath: path]) },
                set: { staged[keyPath: path] = UInt8(clamping: $0); edited = true })
    }

    private func int16Binding(_ path: WritableKeyPath<LocatorConfig, UInt16>) -> Binding<Int> {
        Binding(get: { Int(staged[keyPath: path]) },
                set: { staged[keyPath: path] = UInt16(clamping: $0); edited = true })
    }
}

extension DeployMode {
    /// Listed in wire order, `unused` last — it is the opt-out, not a choice among peers.
    static let allCasesInOrder: [DeployMode] =
        [.droguePrimary, .drogueBackup, .mainPrimary, .mainBackup, .unused]

    /// Android renders `enumValue.name`, so these are the Kotlin case names verbatim.
    /// Prettier spacing would be a second vocabulary for the manual to explain.
    var label: String {
        switch self {
        case .droguePrimary: return "DroguePrimary"
        case .drogueBackup:  return "DrogueBackup"
        case .mainPrimary:   return "MainPrimary"
        case .mainBackup:    return "MainBackup"
        case .unused:        return "Unused"
        }
    }
}

extension NoseAxis {
    static let allCasesInOrder: [NoseAxis] = [.auto, .x, .y, .z]

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .x:    return "X"
        case .y:    return "Y"
        case .z:    return "Z"
        }
    }
}
