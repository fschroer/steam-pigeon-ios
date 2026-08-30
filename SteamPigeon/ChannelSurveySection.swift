import SwiftUI

/// "Find a clean channel" — the tier-3 channel survey (ADR-0019, #33).
///
/// **On demand only.** A sweep costs about a second of deafness and the decision it
/// informs is made once, on the ground.
///
/// Three presentation rules come straight from the ADR, and each exists because the
/// obvious alternative gives wrong advice:
///
/// - **Rank, don't report absolute dBm.** SX126x RSSI near the noise floor is
///   uncalibrated and varies unit to unit, so a level only means something next to the
///   other levels in the same sweep. Levels are shown as a relative bar, not a number.
/// - **Say nothing when every channel is loud.** That is a transmitter next to the
///   receiver, not a busy band, and recommending whichever channel read lowest would be
///   confidently wrong.
/// - **Never imply it predicts the flight.** The sweep measures the receiver's location;
///   the rocket at altitude hears a different and busier world.
///
/// The wording below is Android's, verbatim, because most of it is explaining a
/// measurement rather than labelling a control — and an explanation that differs between
/// the two apps is one the manual has to write twice.
struct ChannelSurveySection: View {
    let survey: ChannelSurvey.Result?
    let inProgress: Bool
    /// Ready, not connected: `connected` is a transient step on the way to `ready`, so
    /// gating on it leaves the button permanently disabled.
    let enabled: Bool
    let locatorConnected: Bool
    /// Whether a pick can act. False while the change it would make is already in
    /// flight, so the button does not sit there accepting taps that go nowhere.
    var canPick: Bool = true
    /// Puts a name against an id the sweep reported. Claimed identity from the air, so it
    /// labels and nothing more.
    var labelOf: (UInt32) -> String? = { _ in nil }
    let onScan: () -> Void
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                // Filled, like Update: these start work rather than offering a choice,
                // and the outlined style read as secondary next to the fields below.
                Button(inProgress ? "Scanning… (about 7 seconds)" : "Find a clean channel",
                       action: onScan)
                    .buttonStyle(.materialFilled)
                    .disabled(!enabled || inProgress)
                // This section's button is its title, so the help hangs off the button.
                // What a pick does depends on whether a locator is connected — moving the
                // whole system or only the receiver — so that line is chosen here rather
                // than being two entries.
                SectionHelp(help: [
                    locatorConnected
                        ? "Moves your locator to the chosen channel; the receiver follows "
                          + "automatically."
                        : "No locator connected, so this only re-points the receiver. Your "
                          + "locator stays where it is.",
                    "Candidates are listened to for a full second each, so an intermittent "
                    + "transmitter cannot hide between samples.",
                    "Measured where the receiver is. A channel that is quiet here may be "
                    + "busier at altitude.",
                ])
            }

            if let survey { results(survey) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func results(_ survey: ChannelSurvey.Result) -> some View {
        switch survey.status {
        case .refusedArmed:
            ChannelNote("The locator is armed. Scanning would stop telemetry for about a "
                        + "second, and the channel cannot be changed while armed. Disarm "
                        + "first.", SPColor.error)
        case .refusedBusy:
            ChannelNote("The receiver is busy — a flight data transfer, or a command "
                        + "still on its way to the locator. Try again in a moment.",
                        SPColor.error)
        // Not an error: the scan gave way to something the user asked for. Its own message,
        // never `refusedBusy`'s — that one is about the receiver being unable to start,
        // which would be a plain lie about what just happened.
        case .cancelled:
            ChannelNote("Scan stopped so your command could reach the locator. Scan again "
                        + "when you are ready.", SPColor.onSurfaceVariant)
        case .unknown:
            ChannelNote("No response from the receiver. If its firmware predates channel "
                        + "scanning, update it — otherwise try again.", SPColor.error)
        case .ok:
            ranking(survey)
        }
    }

    @ViewBuilder private func ranking(_ survey: ChannelSurvey.Result) -> some View {
        // Shown ABOVE the list, not instead of it. Everything reading loud means a
        // transmitter is very close — the important message — but the ranking below is
        // still correct, and refusing to show it leaves a correct warning with no way to
        // act on it.
        //
        // Two different situations, and only one is a problem to solve. Flat and elevated
        // is a nearby transmitter — usually the user's own locator on the bench — bleeding
        // equally across the band; it says nothing about the channels, so it is
        // information, not an error. Elevated with structure means real per-channel
        // traffic, and the ranking below is meaningful.
        if survey.uniformFloor {
            ChannelNote("Every channel reads the same raised level — a transmitter close to "
                        + "the receiver, usually your own locator, spilling across the whole "
                        + "band. It does not favor any channel, so these are all equally "
                        + "good. Move the receiver away from powered locators for a sharper "
                        + "reading.", SPColor.onSurfaceVariant)
        } else if survey.allChannelsHot {
            ChannelNote("Every channel reads loud, which usually means a transmitter is very "
                        + "close to the receiver — check for another powered locator nearby. "
                        + "Move it away and scan again for a true reading. The channels below "
                        + "are still the least affected, and should be clean once it is "
                        + "moved.", SPColor.error)
        }

        if let rank = survey.homeRank {
            ChannelNote("Your channel (\(survey.homeChannel)) ranks \(rank) quietest.",
                        SPColor.onSurfaceVariant)
        }

        ForEach(survey.suggestions, id: \.channel) { s in
            HStack {
                Text("Channel \(s.channel)")
                    .font(SPFont.bodyMedium)
                    .frame(width: 96, alignment: .leading)
                // Relative bar: the quietest channel in THIS sweep is the reference and the
                // loudest is full scale. Deliberately unlabelled in dBm — SX126x RSSI near
                // the floor is uncalibrated, so the number would be a precision the reading
                // does not have.
                ProgressView(value: survey.relativeLevel(s))
                    .padding(.trailing, 8)
                // Different actions, so different labels: with a locator connected this
                // moves the whole system, without one it only re-points the receiver.
                //
                // **Never "Connect"**, unlike a search hit: this points at a channel chosen
                // for being EMPTY, where "Connect" would promise something that is not
                // there.
                Button(locatorConnected ? "Move here" : "Point receiver") { onPick(s.channel) }
                    .buttonStyle(.materialText)
                    .disabled(!canPick)
            }
            .padding(.top, 4)
        }

        // Naming the channels that were excluded, and why, so a short list does not read
        // as a failed scan.
        if survey.homeChannelInUse {
            // With a locator connected the occupant is ours and naming it is just
            // confirmation. With none connected it is someone else's, and the name is the
            // difference between "somebody is on your channel" and "your other rocket is,
            // and you forgot it was powered on".
            let homeWho = survey.confirmed
                .first { $0.channel == survey.homeChannel }
                .flatMap { labelOf($0.locatorId) }
            ChannelNote(homeWho.map { "Your channel (\(survey.homeChannel)) carries \($0)." }
                        ?? (locatorConnected
                            ? "Your channel (\(survey.homeChannel)) carries your locator, as "
                              + "expected."
                            : "Your channel (\(survey.homeChannel)) has a locator on it and "
                              + "none is connected — someone else is using it."),
                        locatorConnected ? SPColor.onSurfaceVariant : SPColor.error)
        }

        // Naming the occupant turns "some channel is busy" into "that is my other rocket",
        // which is the difference between a warning you can act on and one you can only
        // read. Unnamed when the id is unknown or absent — the count alone still says it
        // is occupied.
        ForEach(survey.occupied, id: \.channel) { o in
            let who = labelOf(o.locatorId)
            ChannelNote(who.map { "Channel \(o.channel) has \($0) on it — not offered." }
                        ?? "Channel \(o.channel) has another locator on it — not offered.",
                        SPColor.onSurfaceVariant)
        }
    }
}
