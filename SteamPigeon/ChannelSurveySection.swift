import SwiftUI

/// The channel survey (ADR-0019 tier 3): sweep the band, rank the channels, offer the
/// quietest few.
///
/// **On demand only.** A sweep costs about a second of deafness and the decision it
/// informs is made once, on the ground.
///
/// The wording below is Android's, verbatim, because most of it is explaining a
/// measurement rather than labelling a control — and an explanation that differs
/// between the two apps is one the manual has to write twice.
struct ChannelSurveySection: View {
    let survey: ChannelSurvey.Result?
    let inProgress: Bool
    /// Ready, not connected: `connected` is a transient step on the way to `ready`, so
    /// gating on it leaves the button permanently disabled.
    let enabled: Bool
    let locatorConnected: Bool
    let onScan: () -> Void
    let onPick: (Int) -> Void

    var body: some View {
        Section {
            Button(inProgress ? "Scanning… (about 7 seconds)" : "Find a clean channel", action: onScan)
                .disabled(!enabled || inProgress)

            if let survey { results(survey) }
        } header: {
            Text("Channel")
        }
    }

    @ViewBuilder private func results(_ survey: ChannelSurvey.Result) -> some View {
        switch survey.status {
        case .refusedArmed:
            note("The locator is armed. Scanning would stop telemetry for about a second, "
                 + "and the channel cannot be changed while armed. Disarm first.", .error)
        case .refusedBusy:
            note("A flight data transfer is in progress. Try again when it finishes.", .error)
        case .unknown:
            note("No response from the receiver. If its firmware predates channel "
                 + "scanning, update it — otherwise try again.", .error)
        case .ok:
            ranking(survey)
        }
    }

    @ViewBuilder private func ranking(_ survey: ChannelSurvey.Result) -> some View {
        // Shown ABOVE the list, not instead of it. Everything reading loud means a
        // transmitter is very close — the important message — but the ranking below is
        // still correct, and refusing to show it leaves a correct warning with no way
        // to act on it.
        if survey.uniformFloor {
            note("Every channel reads the same raised level — a transmitter close to the "
                 + "receiver, usually your own locator, spilling across the whole band. It "
                 + "does not favor any channel, so these are all equally good. Move the "
                 + "receiver away from powered locators for a sharper reading.", .muted)
        } else if survey.allChannelsHot {
            note("Every channel reads loud, which usually means a transmitter is very close "
                 + "to the receiver — check for another powered locator nearby. Move it away "
                 + "and scan again for a true reading. The channels below are still the least "
                 + "affected, and should be clean once it is moved.", .error)
        }

        if let rank = survey.homeRank {
            note("Your channel (\(survey.homeChannel)) ranks \(rank) quietest.", .muted)
        }

        ForEach(survey.suggestions, id: \.channel) { s in
            HStack {
                Text("Channel \(s.channel)")
                    .font(SPFont.bodyMedium)
                    .frame(width: 96, alignment: .leading)
                // Relative bar: the quietest channel in THIS sweep is the reference and
                // the loudest is full scale. Deliberately unlabelled in dBm — SX126x
                // RSSI near the floor is uncalibrated, so the number would be a
                // precision the reading does not have.
                ProgressView(value: survey.relativeLevel(s))
                    .padding(.trailing, 8)
                // Different actions, so different labels: with a locator connected
                // this moves the whole system, without one it only re-points the
                // receiver.
                Button(locatorConnected ? "Move here" : "Point receiver") { onPick(s.channel) }
                    .buttonStyle(.borderless)
            }
        }

        note(locatorConnected
             ? "Moves your locator to the chosen channel; the receiver follows automatically."
             : "No locator connected, so this only re-points the receiver. Your locator "
               + "stays where it is.", .muted)

        // Naming the channels that were excluded, and why, so a short list does not read
        // as a failed scan.
        if survey.homeChannelInUse {
            note(locatorConnected
                 ? "Your channel (\(survey.homeChannel)) carries your locator, as expected."
                 : "Your channel (\(survey.homeChannel)) has a locator on it and none is "
                   + "connected — someone else is using it.",
                 locatorConnected ? .muted : .error)
        }
        ForEach(survey.occupied, id: \.channel) { o in
            note("Channel \(o.channel) has another locator on it — not offered.", .muted)
        }

        note("Candidates are listened to for a full second each, so an intermittent "
             + "transmitter cannot hide between samples.", .muted)
        note("Measured where the receiver is. A channel that is quiet here may be busier "
             + "at altitude.", .muted)
    }

    private enum NoteTone { case muted, error }

    private func note(_ text: String, _ tone: NoteTone) -> some View {
        Text(text)
            .font(SPFont.labelSmall)
            .foregroundStyle(tone == .error ? SPColor.error : SPColor.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
