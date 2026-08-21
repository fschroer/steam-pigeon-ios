import SwiftUI

/// Locator Settings — deployment channels, name, channel, mounting axis.
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
        Form {
            Section {
                if let version = model.versionInfo, !version.locatorVersion.isEmpty {
                    LabeledContent("Firmware", value: version.locatorVersion)
                }
                TextField("Locator Name", text: Binding(
                    get: { staged.deviceName },
                    set: {
                        staged.deviceName = String($0.prefix(WireProtocol.deviceNameLength))
                        edited = true
                    }))
                .disabled(busy)

                Stepper(value: channelBinding, in: ReceiverConfig.channelRange) {
                    LabeledContent("Locator Channel to Receive", value: "\(staged.loraChannel)")
                }
                .disabled(busy)

                // Static per installation, but the locator cannot infer it: mounting
                // calibration finds the axis gravity lies along and calls it "up",
                // which is only the nose axis if the rocket happens to be vertical.
                // Stating it is what makes tilt-from-vertical measurable off the pad
                // (ADR-0021 Decision 6).
                Picker("Sensor Axis Along Rocket", selection: Binding(
                    get: { staged.noseAxis },
                    set: { staged.noseAxis = $0; edited = true })) {
                    ForEach(NoseAxis.allCasesInOrder, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(busy)
            }

            ForEach(0..<4, id: \.self) { channel in
                Section("Deployment Channel \(channel + 1)") {
                    Picker("Mode", selection: modeBinding(channel)) {
                        ForEach(DeployMode.allCasesInOrder, id: \.self) { Text($0.label).tag($0) }
                    }
                    .disabled(busy)
                    // Only the field belonging to the SELECTED mode is shown, as
                    // Android does — a delay box under a channel set to Main is a
                    // value with nothing to apply to.
                    modeDetail(for: mode(channel))
                }
            }

            Section {
                Button(model.locatorConfigMessageState.buttonLabel) {
                    model.changeLocatorConfig(staged)
                    edited = false
                }
                .disabled(!edited || busy)
            } footer: {
                Text("Sends the locator's complete settings. The link drops briefly if the "
                     + "channel changed, while both devices switch.")
            }
        }
        .navigationTitle("Locator Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.remoteLocatorConfig) { latest in
            if !edited { staged = latest }
        }
        .onAppear { staged = model.remoteLocatorConfig }
    }

    // MARK: - Bindings

    private var channelBinding: Binding<Int> {
        Binding(get: { staged.loraChannel }, set: { staged.loraChannel = $0; edited = true })
    }

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
            tenthsStepper("Drogue Primary Deploy Delay (s)",
                          value: Binding(get: { staged.droguePrimaryDelay },
                                         set: { staged.droguePrimaryDelay = $0; edited = true }),
                          range: 0...max(Int(staged.drogueBackupDelay) - 1, 0))
        case .drogueBackup:
            tenthsStepper("Drogue Backup Deploy Delay (s)",
                          value: Binding(get: { staged.drogueBackupDelay },
                                         set: { staged.drogueBackupDelay = $0; edited = true }),
                          range: min(Int(staged.droguePrimaryDelay) + 1, 30)...30)
        case .mainPrimary:
            metresStepper("Main Primary Deploy Altitude (m)",
                          value: Binding(get: { staged.mainPrimaryAltitude },
                                         set: { staged.mainPrimaryAltitude = $0; edited = true }),
                          range: min(Int(staged.mainBackupAltitude) + 1, 500)...500)
        case .mainBackup:
            metresStepper("Main Backup Deploy Altitude (m)",
                          value: Binding(get: { staged.mainBackupAltitude },
                                         set: { staged.mainBackupAltitude = $0; edited = true }),
                          range: 0...max(Int(staged.mainPrimaryAltitude) - 1, 0))
        case .unused:
            EmptyView()
        }
    }

    /// Delays are stored in TENTHS of a second and shown in seconds.
    private func tenthsStepper(_ title: String, value: Binding<UInt8>,
                               range: ClosedRange<Int>) -> some View {
        Stepper(value: Binding(get: { Int(value.wrappedValue) },
                               set: { value.wrappedValue = UInt8(clamping: $0) }),
                in: range) {
            LabeledContent(title, value: String(format: "%.1f", Double(value.wrappedValue) / 10))
        }
        .disabled(busy || range.isEmpty)
    }

    private func metresStepper(_ title: String, value: Binding<UInt16>,
                               range: ClosedRange<Int>) -> some View {
        Stepper(value: Binding(get: { Int(value.wrappedValue) },
                               set: { value.wrappedValue = UInt16(clamping: $0) }),
                in: range) {
            LabeledContent(title, value: "\(value.wrappedValue)")
        }
        .disabled(busy || range.isEmpty)
    }
}

extension DeployMode {
    /// Listed in wire order, `unused` last — it is the opt-out, not a choice among peers.
    static let allCasesInOrder: [DeployMode] =
        [.droguePrimary, .drogueBackup, .mainPrimary, .mainBackup, .unused]

    var label: String {
        switch self {
        case .droguePrimary: return "Drogue Primary"
        case .drogueBackup:  return "Drogue Backup"
        case .mainPrimary:   return "Main Primary"
        case .mainBackup:    return "Main Backup"
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
