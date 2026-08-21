import SwiftUI

/// Receiver Settings — name, LoRa channel, firmware version.
///
/// Mirrors Android's `ReceiverSettingsScreen`, minus the channel survey and the
/// ADR-0011 channel-move flow, which are a following pass. What is here is the staged
/// form and its Cancel/Update row.
///
/// **Edits are STAGED, never live.** Typing a channel does not retune anything; the
/// Update button sends, and the button then reports what the receiver said. That
/// matters more than it looks: a config change that silently did nothing is
/// indistinguishable from one that never arrived, which is the failure this screen
/// exists to make visible.
struct ReceiverSettingsView: View {
    @ObservedObject var model: LinkViewModel

    /// The user's pending edit. Kept in step with the receiver until they touch it —
    /// after that it is theirs, and an arriving broadcast must not overwrite what they
    /// are halfway through typing.
    @State private var staged = ReceiverConfig()
    @State private var edited = false

    /// The ADR-0011 move cycle, reported as it happens.
    ///
    /// It can legitimately run for several seconds with the link DOWN — the locator
    /// switches, the receiver follows, and a failed move is recovered by pulling the
    /// receiver back and retrying once. Silence through all that reads as a hang, which
    /// is why every state says something.
    private func moveProgress(_ channel: Int) -> (text: String, isError: Bool)? {
        switch model.locatorConfigMessageState {
        case .sendRequested, .sent:
            return ("Moving to channel \(channel)… the link drops briefly while both "
                    + "devices switch.", false)
        case .ackUpdated:
            return ("Now on channel \(channel).", false)
        case .sendFailure:
            return ("Could not send the channel change. Check the receiver connection.", true)
        case .notAcknowledged:
            return ("The locator did not confirm channel \(channel). It has been left on "
                    + "its previous channel.", true)
        case .idle:
            return nil
        }
    }

    var body: some View {
        Form {
            ChannelSurveySection(
                survey: model.channelSurvey,
                inProgress: model.surveyInProgress,
                enabled: model.state == .ready,
                locatorConnected: model.connectedLocatorId != nil,
                onScan: { model.requestChannelSurvey() },
                // Two different actions behind one control, and the difference is the
                // point: with a locator connected this moves the WHOLE system, because
                // re-pointing the receiver alone would strand the locator on the old
                // channel (ADR-0011 invariant 1 vs 5).
                onPick: { channel in
                    if model.connectedLocatorId != nil {
                        model.moveLocatorToChannel(channel)
                    } else {
                        staged.channel = channel
                        edited = true
                    }
                })

            if let channel = model.pendingChannelMove, let progress = moveProgress(channel) {
                Section {
                    HStack(alignment: .top) {
                        Text(progress.text)
                            .font(SPFont.labelSmall)
                            .foregroundStyle(progress.isError ? SPColor.error
                                                              : SPColor.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Dismiss") { model.clearPendingChannelMove() }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section {
                if let version = model.versionInfo, !version.receiverVersion.isEmpty {
                    LabeledContent("Firmware", value: version.receiverVersion)
                }

                TextField("Receiver Name", text: Binding(
                    get: { staged.deviceName },
                    set: {
                        // The field is fixed-width on the wire; truncate as it is typed
                        // rather than silently dropping the tail on send.
                        staged.deviceName = String($0.prefix(WireProtocol.deviceNameLength))
                        edited = true
                    }))
                .disabled(model.receiverConfigMessageState.isInFlight)

                Stepper(value: Binding(
                    get: { staged.channel },
                    set: { staged.channel = $0; edited = true }),
                        in: ReceiverConfig.channelRange) {
                    LabeledContent("LoRa Channel", value: "\(staged.channel)")
                }
                .disabled(model.receiverConfigMessageState.isInFlight)
            } footer: {
                // Android's own framing: this points the RECEIVER at a different
                // locator's channel. Changing a locator's own channel is Locator
                // Settings, where the receiver follows automatically.
                Text("Changes the channel this receiver listens on, to reach a locator "
                     + "already using another channel. To move a connected locator, use "
                     + "Locator Settings.")
            }

            // Android pairs Update with a "Return to main" button. On iOS that is the
            // sheet's own Done, which ADR-0016 already sanctions in place of an app-bar
            // control — so the row is Update alone rather than Update plus a second way
            // to leave. A Revert button was drafted here and removed: Android has none,
            // and inventing one is how the two apps stop needing the same manual.
            Section {
                Button(model.receiverConfigMessageState.buttonLabel) {
                    model.changeReceiverConfig(staged)
                    edited = false
                }
                .disabled(!edited || model.receiverConfigMessageState != .idle)
            }
        }
        .navigationTitle("Receiver Settings")
        .navigationBarTitleDisplayMode(.inline)
        // Keep the staged copy in step with the receiver as long as the user has not
        // edited it, so an arriving broadcast or a receiver switch shows immediately
        // rather than leaving last session's values on screen.
        .onChange(of: model.remoteReceiverConfig) { latest in
            if !edited { staged = latest }
        }
        .onAppear {
            staged = model.remoteReceiverConfig
            // If nothing has been heard recently, ask. A receiver with no locator on
            // its channel never volunteers anything, and that is precisely the state
            // someone opens this screen to get out of.
            if !model.isLocatorFresh { model.requestReceiverInfo() }
        }
    }
}
