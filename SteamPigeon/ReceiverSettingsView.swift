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

    /// Android formats the id as `%08X`, and it is worth matching exactly: this is the
    /// number a user reads out to someone else on the flight line.
    private static func hex(_ id: UInt32) -> String { String(format: "%08X", id) }

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
        // Scrolling column with the Update button pinned below, matching Android's
        // layout — and matching Locator Settings, which is the screen it is most often
        // compared with.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Conflicting traffic (ADR-0006). Non-blocking on purpose: it is a
                    // fact about the channel, not a modal decision, and the two actions
                    // are the whole point — switch to it, or move to an uncontested
                    // channel using the survey directly below.
                    if let id = model.conflictLocatorId {
                        // Two different situations, and only one of them is a problem.
                        // Already connected to a DIFFERENT locator: genuine conflicting
                        // traffic. Not connected at all: simply a new locator to connect
                        // to, so the wording invites rather than warns.
                        let connected = model.connectedLocatorId != nil
                        Text(connected
                             ? "Another locator (ID \(Self.hex(id))) is on the air and is "
                               + "not being displayed. Connect to switch to it, or move to "
                               + "an uncontested channel."
                             : "Locator ID \(Self.hex(id)) found. Enter its password to connect.")
                            .font(SPFont.bodySmall)
                            .foregroundStyle(connected ? SPColor.error : SPColor.onBackground)
                        HStack {
                            Button("Connect") { model.requestConnectToConflict() }
                            Spacer()
                            Button("Dismiss") { model.dismissConflict() }
                        }
                        .buttonStyle(.borderless)
                        Divider()
                    }

                    ChannelSurveySection(
                        survey: model.channelSurvey,
                        inProgress: model.surveyInProgress,
                        enabled: model.state == .ready,
                        locatorConnected: model.connectedLocatorId != nil,
                        onScan: { model.requestChannelSurvey() },
                        // Two different actions behind one control, and the difference
                        // is the point: with a locator connected this moves the WHOLE
                        // system, because re-pointing the receiver alone would strand
                        // the locator on the old channel (ADR-0011 invariant 1 vs 5).
                        onPick: { channel in
                            if model.connectedLocatorId != nil {
                                model.moveLocatorToChannel(channel)
                            } else {
                                staged.channel = channel
                                edited = true
                            }
                            // Either way the ranking is spent: it described the band
                            // before the move. Android clears it on both branches.
                            model.clearChannelSurvey()
                        })

                    if let channel = model.pendingChannelMove, let progress = moveProgress(channel) {
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

                    Divider().padding(.vertical, 4)

                    if let version = model.versionInfo, !version.receiverVersion.isEmpty {
                        Text("Firmware: \(version.receiverVersion)")
                            .font(SPFont.bodyMedium)
                            .foregroundStyle(SPColor.onSurfaceVariant)
                    }

                    ConfigTextRow(title: "Receiver Name",
                                  text: Binding(get: { staged.deviceName },
                                                set: { staged.deviceName = $0; edited = true }),
                                  enabled: model.receiverConfigMessageState == .idle)

                    ConfigIntRow(title: "Locator Channel to Receive",
                                 value: Binding(get: { staged.channel },
                                                set: { staged.channel = $0; edited = true }),
                                 range: ReceiverConfig.channelRange,
                                 enabled: model.receiverConfigMessageState == .idle)

                    // Android's own framing: this points the RECEIVER at a different
                    // locator's channel. Changing a locator's own channel is Locator
                    // Settings, where the receiver follows automatically.
                    Text("Changes the channel this receiver listens on, to reach a locator "
                         + "already using another channel. To move a connected locator, use "
                         + "Locator Settings.")
                        .font(SPFont.labelSmall)
                        .foregroundStyle(SPColor.onSurfaceVariant)
                }
                .padding(16)
            }

            Divider()
            Button(model.receiverConfigMessageState.buttonLabel) {
                model.changeReceiverConfig(staged)
                edited = false
            }
            .buttonStyle(.borderedProminent)
            .disabled(!edited || model.receiverConfigMessageState != .idle)
            .padding(16)
        }
        .background(SPColor.background)
        .navigationTitle("Receiver Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.remoteReceiverConfig) { latest in
            if !edited { staged = latest }
        }
        .onAppear {
            staged = model.remoteReceiverConfig
            // If nothing has been heard recently, ask. A receiver with no locator on
            // its channel never volunteers anything, and that is precisely the state
            // someone opens this screen to get out of.
            if !model.isLocatorFresh { model.requestReceiverInfo() }
            // Re-entering the screen is the user asking to see conflicts again, so a
            // dismissal from a previous visit does not persist.
            model.resetConflictDismissals()
        }
    }

}
