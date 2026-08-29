import SwiftUI

/// Receiver Settings — firmware version and name.
///
/// Mirrors Android's `ReceiverSettingsScreen`. **The channel, both scans and the
/// ADR-0011 move flow moved to the Communication screen** (ADR-0029): the old grouping
/// was by *device*, and "which channel am I listening on" is not a question about a
/// device. What is left here is the receiver's identity.
///
/// **Edits are STAGED, never live.** Typing a name does not rename anything; the Update
/// button sends, and the button then reports what the receiver said. That matters more
/// than it looks: a config change that silently did nothing is indistinguishable from one
/// that never arrived, which is the failure this screen exists to make visible.
///
/// **The message is built from the last read-back, changing only this screen's field.**
/// Name and channel ride in one message but are now edited on two screens, so sending a
/// locally-staged copy of the whole struct would let a rename quietly revert a channel
/// change made over there.
struct ReceiverSettingsView: View {
    @ObservedObject var model: LinkViewModel

    /// The user's pending edit. Kept in step with the receiver until they touch it —
    /// after that it is theirs, and an arriving broadcast must not overwrite what they
    /// are halfway through typing.
    @State private var stagedName = ""
    @State private var edited = false

    /// Android formats the id as `%08X`, and it is worth matching exactly: this is the
    /// number a user reads out to someone else on the flight line.
    private static func hex(_ id: UInt32) -> String { String(format: "%08X", id) }

    var body: some View {
        // Scrolling column with the Update button pinned below, matching Android's
        // layout — and matching Locator Settings, which is the screen it is most often
        // compared with.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Conflicting traffic (ADR-0006). Non-blocking on purpose: it is a
                    // fact about the channel, not a modal decision.
                    //
                    // **Also shown on the Communication screen**, where the two remedies
                    // now live. It stays here because the banner is raised by a broadcast
                    // arriving, not by a screen being open, and a user who is on this
                    // screen when a stranger appears should still be told.
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
                        .buttonStyle(.materialText)
                        Divider()
                    }

                    if let version = model.versionInfo, !version.receiverVersion.isEmpty {
                        Text("Firmware: \(version.receiverVersion)")
                            .font(SPFont.bodyMedium)
                            .foregroundStyle(SPColor.onSurfaceVariant)
                    }

                    ConfigTextRow(title: "Receiver Name",
                                  text: Binding(get: { stagedName },
                                                set: { stagedName = $0; edited = true }),
                                  enabled: model.receiverConfigMessageState == .idle)

                    Text("The channel this receiver listens on is set on the Communication "
                         + "screen, next to the scans that choose one.")
                        .font(SPFont.labelSmall)
                        .foregroundStyle(SPColor.onSurfaceVariant)
                }
                .padding(16)
            }

            Divider()
            Button(model.receiverConfigMessageState.buttonLabel) {
                var target = model.remoteReceiverConfig
                target.deviceName = stagedName
                model.changeReceiverConfig(target)
                edited = false
            }
            .buttonStyle(.materialFilled)
            .disabled(!edited || model.receiverConfigMessageState != .idle)
            .padding(16)
        }
        .background(SPColor.background)
        .navigationTitle("Receiver Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.remoteReceiverConfig) { latest in
            if !edited { stagedName = latest.deviceName }
        }
        .onAppear {
            stagedName = model.remoteReceiverConfig.deviceName
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
