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

    var body: some View {
        Form {
            ChannelSurveySection(
                survey: model.channelSurvey,
                inProgress: model.surveyInProgress,
                enabled: model.state == .ready,
                locatorConnected: model.connectedLocatorId != nil,
                onScan: { model.requestChannelSurvey() },
                // Withheld while a locator is connected — moving the whole system is
                // ADR-0011 and needs Locator Settings, which is not ported. Staging the
                // receiver-only half would strand the locator on the old channel.
                onPick: model.connectedLocatorId == nil
                    ? { channel in
                        staged.channel = channel
                        edited = true
                      }
                    : nil)

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
