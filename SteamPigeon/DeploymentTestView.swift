import SwiftUI

/// Deployment Test — fire one pyro channel on the ground, from a distance.
///
/// Mirrors Android's `DeploymentTestScreen`. Pick a channel, start the test, watch the
/// locator's countdown, and stop it if you need to.
///
/// **ADR-0027: this is the only way to fire a channel.** The USB-C console path was
/// removed because it put the operator's hand about a metre from the e-match; the radio
/// path is the one that buys actual distance, so it is the one that survived. Everything
/// on this screen follows from that: the countdown is the locator's, not the app's, and
/// the stop control is visible before it is needed rather than hunted for during a
/// countdown.
///
/// The screen is reachable only while the locator is ARMED, because that is when the
/// outputs are live — see `MenuGating`, and ADR-0021 for why arming gates the pyro bus
/// and nothing else.
struct DeploymentTestView: View {
    @ObservedObject var model: LinkViewModel
    /// Closes the screen — Android's `onCancelButtonClicked`.
    var onReturn: () -> Void

    @State private var option: DeploymentTestOption = .none

    /// The spacing Android writes out around these controls. Heights, padding, shape and
    /// colour all live in `MaterialButtonStyle`, which is where Compose gets them from.
    private enum Metrics {
        /// `Modifier.height(48.dp)` on the stop button — taller than the rest, because it
        /// is the control someone reaches for while a charge is counting down.
        static let stopButtonHeight: CGFloat = 48
        /// `Modifier.padding(top = 12.dp)` on the stop button.
        static let stopButtonTopGap: CGFloat = 12
        /// `EnumDropdown` carries `padding(bottom = 16.dp)` on Android.
        static let belowDropdown: CGFloat = 16
        /// `Column(modifier.padding(start = 40.dp))`, inside the screen's own 16.
        static let columnInset: CGFloat = 40
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Android renders the enum's case names here, so `Channel1`, not
                // "Channel 1" — the same string the manual prints for both platforms.
                ConfigPickerRow(selection: $option,
                                options: DeploymentTestOption.allCases,
                                label: \.label)
                    // `EnumDropdown` carries this below itself on Android.
                    .padding(.bottom, Metrics.belowDropdown)

                startButton
                stopButton
            }
            // Android insets this column from the left rather than centring it.
            .padding(.leading, Metrics.columnInset)

            Spacer()

            // Android's `OutlinedButton` carries `weight(1f)`, so it fills the row, and
            // takes Material's default height like every other button here.
            Button(action: onReturn) {
                Text("Return").frame(maxWidth: .infinity)
            }
            .buttonStyle(.materialOutlined)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SPColor.background)
        // Leaving cancels a running test. The state is deliberately NOT cleared — see
        // `LinkViewModel.leaveDeploymentTest`.
        .onDisappear { model.leaveDeploymentTest() }
    }

    /// Start only.
    ///
    /// It used to be the cancel as well, which is why Android's manual had to warn that a
    /// press landing just after the countdown lapsed would start a FRESH test — the worst
    /// possible outcome for someone stabbing at the button trying to stop one. Stopping
    /// has its own control below, so this one is simply disabled for the duration and
    /// shows the count.
    private var startButton: some View {
        Button {
            model.startDeploymentTest(option)
        } label: {
            Text(startLabel)
        }
        .buttonStyle(.materialFilled)
        .disabled(option == .none || model.deploymentTestActive)
    }

    private var startLabel: String {
        if option == .none { return "Select Deployment Channel" }
        if model.deploymentTestCountdown > 0 { return "\(model.deploymentTestCountdown)" }
        if model.deploymentTestActive { return "Deployment Channel \(option.channelNumber) Test…" }
        return "Deployment Channel \(option.channelNumber) Test"
    }

    /// Stop.
    ///
    /// Present and visible from the moment the screen opens — greyed out until there is
    /// something to stop — so the way out is known BEFORE the countdown starts rather
    /// than hunted for during it. Error-coloured to match the disarm button on the flight
    /// map, which is the other control that makes a rocket safer.
    private var stopButton: some View {
        Button {
            model.cancelDeploymentTest()
        } label: {
            Text(model.deploymentTestCancelPending ? "STOPPING…" : "STOP TEST")
        }
        // Error container, `onError` label — the treatment the disarm button gets on the
        // flight map, which is the other control that makes a rocket safer. The disabled
        // colours come from the style, so a dead control drops to neutral rather than
        // staying red, exactly as Material does.
        .buttonStyle(.materialFilled(container: SPColor.error, content: SPColor.onError,
                                     minHeight: Metrics.stopButtonHeight))
        .disabled(!model.deploymentTestActive)
        .padding(.top, Metrics.stopButtonTopGap)
    }
}
