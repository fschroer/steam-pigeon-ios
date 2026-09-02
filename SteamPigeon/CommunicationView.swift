import SwiftUI

/// Everything about **which channel you are listening to**, in one place.
///
/// Split out of Receiver Settings because the old grouping was by *device* and the
/// question is not about a device. Someone who powers a rocket up and hears nothing is
/// not thinking "receiver configuration" — they are thinking "where is my locator", and
/// the tools that answer it were filed under the hardware that happens to perform the
/// search.
///
/// The controls are one workflow, in the order you actually reach for them: find the
/// locator you have lost, find a channel worth moving to, point the receiver by hand,
/// move the locator by hand. The middle two appear only when they can do anything — see
/// the gate at each.
///
/// **Choosing from a list acts; typing a number needs Update.** A channel picked out of a
/// scan result is a decision already made — the search just established that the locator
/// is on 48, and there is nothing left to confirm — so the button applies. A number being
/// typed has no such moment, since every keystroke is a valid channel, so the field keeps
/// an Update button. Android's first cut staged the picks as well, which meant tapping
/// "Point receiver" appeared to do nothing and left the real action in a different
/// section of the screen.
///
/// **Two devices, two Update buttons, deliberately.** The receiver's channel and the
/// locator's channel are different messages with different acknowledgement paths (the
/// receiver echoes over BLE; the locator is confirmed by inference through ADR-0011's
/// recognition cycle). One button over both would have to hide that difference, and the
/// difference is exactly what a user needs to see when one of them does not take.
///
/// Ported from Android's `CommunicationScreen.kt`.
struct CommunicationView: View {
    @ObservedObject var model: LinkViewModel

    /// Which locator the search should stop on; nil = report everything it finds, which
    /// is also the only thing that works for a borrowed locator the app has never heard
    /// of.
    @State private var searchTargetId: UInt32?

    /// Staged channels are **local to this screen**, not the shared edited flag Receiver
    /// Settings uses for the name. The two screens now edit different fields of the same
    /// struct, and a shared dirty flag would let a name staged over there light up the
    /// Update button over here with nothing to send.
    @State private var stagedReceiverChannel = 0
    @State private var stagedLocatorChannel = 0

    /// "The user typed here" is **tracked, not derived**. Deriving it from
    /// `staged != remote` reads correctly and behaves backwards: the sync below runs
    /// BECAUSE the device value changed, which is the moment the two are guaranteed to
    /// differ, so a derived flag is true exactly when the sync is needed and blocks it.
    /// On Android that left the locator channel reading 0 — the screen composed before
    /// the locator's config had arrived, seeded 0, then refused every update on the
    /// grounds that 0 was an edit in progress, with an enabled Update button that would
    /// have moved a locator to channel 0.
    @State private var receiverChannelEdited = false
    @State private var locatorChannelEdited = false

    /// Recomputed on a tick, because silence generates no event — see
    /// `LinkViewModel.isHearingLocator`.
    @State private var hearingLocator = false

    private var locatorConnected: Bool { model.connectedLocatorId != nil }
    private var receiverChannelChanged: Bool {
        stagedReceiverChannel != model.remoteReceiverConfig.channel
    }
    private var locatorChannelChanged: Bool {
        stagedLocatorChannel != model.remoteLocatorConfig.loraChannel
    }

    /// Ready, not connected: `connected` is a transient step on the way to `ready`, so
    /// gating on it leaves the buttons permanently disabled.
    private var linkReady: Bool { model.state == .ready }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                conflictBanner
                channelMoveBanner

                // Said once, above both scans, because one condition disables both and
                // two identical notes read as two problems.
                if model.locatorArmedOrFlying {
                    ChannelNote("The locator is armed or in flight, so neither scan can "
                                + "run — either would leave the receiver deaf for up to a "
                                + "minute and a half. Disarm to scan.", SPColor.error)
                }

                // Search first, scan second. This screen is opened far more often
                // because something is missing than because something is noisy.
                LocatorSearchSection(
                    run: model.locatorSearch,
                    knownLocators: model.knownLocatorLabels,
                    targetId: $searchTargetId,
                    candidates: model.searchCandidates(targetLocatorId: searchTargetId),
                    enabled: linkReady && model.locatorSearch?.running != true
                             && !model.surveyInProgress
                             && !model.locatorArmedOrFlying,
                    currentChannel: model.remoteReceiverConfig.channel,
                    connectedLocatorId: model.connectedLocatorId,
                    // A change is already on its way to the receiver. Connect stays
                    // visible but stops responding, because the send would be refused
                    // and a control that silently does nothing is the failure this
                    // screen exists to avoid.
                    canConnect: model.receiverConfigMessageState == .idle,
                    onSearch: { channels in
                        model.startLocatorSearch(channels: channels,
                                                 targetLocatorId: searchTargetId ?? 0)
                    },
                    onCancel: { model.cancelLocatorSearch() },
                    onPick: { channel in
                        // Receiver-only, always. The locator is already ON that channel —
                        // that is what the search just established — so moving it would
                        // be the one action guaranteed to lose it again.
                        //
                        // The staged value moves with it, or the field below would sit at
                        // the old number offering to undo what this just did — but ONLY
                        // if the change actually went out. Staging first and asking
                        // afterwards put a channel the app never visited into the field,
                        // with an enabled Update button offering to apply it.
                        if model.pointReceiverAtChannel(channel) {
                            stagedReceiverChannel = channel
                            receiverChannelEdited = false
                        }
                        // Results are deliberately NOT cleared: the hit just acted on is
                        // the thing worth still seeing, and the row now reports that the
                        // receiver is there.
                    })

                // Shown only while a locator is being heard. "Find a clean channel" is
                // for a link that is working badly; with nothing coming through, the
                // question is not which channel is quiet but where the rocket is, and
                // that is the section above.
                //
                // This NARROWS ADR-0019, whose tier-2 addendum argued for offering the
                // sweep from the no-locator state: it is the one instrument that catches
                // a continuous non-LoRa emitter, which the passive path cannot see. That
                // diagnostic is unreachable without a locator now, and ADR-0029 records
                // the trade rather than leaving it to be rediscovered.
                //
                // **But never hide a scan this section is running, or the answer it
                // produced.** The rule above is about OFFERING the sweep. A sweep leaves
                // the receiver deaf for ~7.8 s — longer than the 5 s silence window — so
                // gating on `hearingLocator` alone made the section hide itself about
                // five seconds into its own scan, taking the "Scanning…" indicator with
                // it, and reappear with the results once broadcasts resumed. Reported
                // from the Android bench 2026-08-30 as the indicator vanishing and
                // results arriving 3–4 seconds later; the scan was running the whole
                // time.
                //
                // `model.channelSurvey != nil` is load-bearing, not belt-and-braces.
                // Without it the section hides again at the instant the results land —
                // the sweep has ended, so `surveyInProgress` is false, while the
                // locator's next broadcast is still up to a second away — and flickers
                // back a moment later. Results do not linger across visits: the
                // entry-time clear drops them, with the same "except one still running"
                // exception.
                //
                // Same lesson as that entry-time clear: a rule about when to START
                // something must not be applied to something already under way.
                if ChannelSurveySection.isOffered(hearingLocator: hearingLocator,
                                                  surveyInProgress: model.surveyInProgress,
                                                  hasResult: model.channelSurvey != nil) {
                    Divider().padding(.vertical, 12)

                    ChannelSurveySection(
                        survey: model.channelSurvey,
                        inProgress: model.surveyInProgress,
                        enabled: linkReady && !model.surveyInProgress
                                 && model.locatorSearch?.running != true
                                 && !model.locatorArmedOrFlying,
                        locatorConnected: locatorConnected,
                        // Which device the pick commands decides which in-flight change
                        // has to finish first.
                        canPick: locatorConnected
                            ? model.locatorConfigMessageState == .idle
                            : model.receiverConfigMessageState == .idle,
                        labelOf: { model.storedLabel(for: $0) },
                        onScan: { model.requestChannelSurvey() },
                        onCancel: { model.cancelChannelSurvey() },
                        onPick: { channel in
                            if locatorConnected {
                                // Move the whole system. "Find a clean channel" means the
                                // rocket goes there too — staging a receiver-only change
                                // would point the receiver at an empty channel and strand
                                // the locator behind on the old one (ADR-0011 invariant
                                // 1 vs 5).
                                model.moveLocatorToChannel(channel)
                            } else {
                                // Nothing to move: point the receiver, the legitimate "go
                                // look at that channel" case. Applied on the tap for the
                                // same reason the search's pick is — choosing from a
                                // ranked list is the decision, not a draft of one.
                                if model.pointReceiverAtChannel(channel) {
                                    stagedReceiverChannel = channel
                                    receiverChannelEdited = false
                                }
                            }
                            model.clearChannelSurvey()
                        })
                }

                Divider().padding(.vertical, 12)

                // No help on the heading. The two fields do different things to different
                // devices, and one icon holding both paragraphs made the reader work out
                // which applied to which — the question the icon was meant to answer.
                // Each field carries its own instead.
                Text("Set a channel by hand")
                    .font(SPFont.titleMedium)
                    .foregroundStyle(SPColor.onBackground)

                receiverChannelSection
                if locatorConnected { locatorChannelSection }
            }
            .padding(16)
        }
        .background(SPColor.background)
        .onAppear {
            stagedReceiverChannel = model.remoteReceiverConfig.channel
            stagedLocatorChannel = model.remoteLocatorConfig.loraChannel
            hearingLocator = model.isHearingLocator()
            // Re-entering is the user asking to see conflicts again, so a dismissal from
            // a previous visit does not persist.
            model.resetConflictDismissals()
            // And neither scan's results persist across a visit — both live in the view
            // model, so re-entering showed minutes-old findings as though they were
            // current. A run still in progress is left alone; the rule and the reasons
            // are in `clearScansForNewVisit`.
            model.clearScansForNewVisit()
            // With no locator being heard, ReceiverInfo over BLE is the only way to learn
            // the channel we are actually on — and being on the wrong one is the whole
            // reason to open this screen.
            if !model.isHearingLocator() { model.requestReceiverInfo() }
        }
        // Android's 1 s `LaunchedEffect` loop. Cancelled on disappear, as the composable's
        // coroutine is.
        .task {
            while !Task.isCancelled {
                hearingLocator = model.isHearingLocator()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Follow the device while the user has not typed anything, so a late-arriving
        // config or a channel changed from elsewhere shows up immediately — but never
        // overwrite a number being edited.
        .onChange(of: model.remoteReceiverConfig.channel) { latest in
            if !receiverChannelEdited { stagedReceiverChannel = latest }
        }
        .onChange(of: model.remoteLocatorConfig.loraChannel) { latest in
            if !locatorChannelEdited { stagedLocatorChannel = latest }
        }
        // Android's screen solicits confirmation after a receiver change — PreLaunchData
        // may no longer arrive, which is exactly what changing channel does, so BLE is
        // the only ack path. **Not repeated here**: on iOS that lives inside
        // `changeReceiverConfig`, which already sends a `ReceiverInfoRequest` 300 ms after
        // the change and then polls for the echo. Doing it in the view as well would put
        // two requests on the link for one change.
    }

    // MARK: - Banners

    /// Conflicting traffic: another locator is audible and is not the one being
    /// displayed. It belongs here rather than with the receiver's settings — "somebody
    /// else is on your channel" is a channel fact, and the two remedies (switch to it, or
    /// move away from it) are both on this screen.
    @ViewBuilder private var conflictBanner: some View {
        if let id = model.conflictLocatorId {
            HStack {
                Text(locatorConnected
                     ? "Another locator (ID \(Self.hex(id))) is on the air and is not being "
                       + "displayed. Connect to switch to it, or move to an uncontested channel."
                     : "Locator ID \(Self.hex(id)) found. Enter its password to connect.")
                    .font(SPFont.bodySmall)
                    .foregroundStyle(locatorConnected ? SPColor.error : SPColor.onBackground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Connect") { model.requestConnectToConflict() }
                Button("Dismiss") { model.dismissConflict() }
            }
            .buttonStyle(.materialText)
            .padding(.bottom, 8)
        }
    }

    /// Progress for a locator channel move. The ADR-0011 cycle waits for PreLaunchData to
    /// resume on the new channel and may revert and retry once, so this runs for several
    /// seconds with the link legitimately down — silence there reads as a hang.
    @ViewBuilder private var channelMoveBanner: some View {
        // Dismiss hides the MESSAGE, not the staged channel: that channel is what the
        // ADR-0029 search looks on after a failed move, and it used to be thrown away by
        // the act of clearing the error describing it.
        //
        // The terminal state is read from `channelMoveResult`, which outlives the 2 s
        // `.idle` reset — the outcome of a cycle that can run ~23 s used to be on screen
        // for two.
        if let channel = model.channelMoveBannerChannel,
           let progress = moveProgress(channel) {
            HStack(alignment: .top) {
                Text(progress.text)
                    .font(SPFont.labelSmall)
                    .foregroundStyle(progress.isError ? SPColor.error : SPColor.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss") { model.dismissChannelMoveBanner() }
                    .buttonStyle(.materialText)
            }
            .padding(.bottom, 8)
        }
    }

    private func moveProgress(_ channel: Int) -> (text: String, isError: Bool)? {
        switch model.channelMoveResult ?? model.locatorConfigMessageState {
        case .sendRequested, .sent:
            return ("Moving to channel \(channel)… the link drops briefly while both "
                    + "devices switch.", false)
        case .ackUpdated:
            return ("Now on channel \(channel).", false)
        case .sendFailure:
            return ("Could not send the channel change. Check the receiver connection.", true)
        case .notAcknowledged:
            // Three different endings share this state and leave the hardware in different
            // places — see `model.channelMoveOutcome`.
            //
            // **No sentence may claim the receiver is somewhere the app has not read.**
            // These messages used to name the ATTEMPTED channel, which is false whenever
            // the forward never transmitted: with the locator already silent no forwarding
            // window ever opens, so the receiver never follows and is still on the old
            // channel. Reported from the Android bench 2026-08-30 — right verdict, wrong
            // sentence. The receiver's own channel is known here regardless, because the
            // channel watch polls `ReceiverInfo` every 2 s while the locator is quiet.
            //
            // Which sentence is earned is decided in `ChannelMove.message` and pinned
            // there; this only maps it to words. Three of this amendment's defects were
            // messages rather than logic, so the choice does not live inline in a view.
            let here = model.remoteReceiverConfig.channel
            switch ChannelMove.message(verdict: model.channelMoveOutcome,
                                       attemptedChannel: channel,
                                       receiverChannel: here) {
            case .notChecked:
                return ("Could not check where the locator is — the receiver was busy. "
                        + "The receiver is on channel \(here); use Find a locator.", true)
            case .nothingMoved:
                // Ordinary text, not error colour: a much smaller problem than a stranded
                // locator, and the user should not have to work out which they have.
                return ("The locator did not respond, so nothing was moved. The receiver "
                        + "is still on channel \(here) — power the locator up and the "
                        + "link should resume.", false)
            case .unresolved:
                return ("Could not confirm where the locator is. The receiver is on "
                        + "channel \(here) — if the locator does not come back, use "
                        + "Find a locator.", true)
            case .succeeded, .leftOnPrevious:
                return ("The locator did not confirm channel \(channel). It has been "
                        + "left on its previous channel.", true)
            }
        case .idle:
            return nil
        }
    }

    // MARK: - Manual channel fields

    private var receiverChannelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                ConfigIntRow(title: "Receiver channel",
                             value: Binding(get: { stagedReceiverChannel },
                                            set: { stagedReceiverChannel = $0
                                                   receiverChannelEdited = true }),
                             range: ReceiverConfig.channelRange,
                             enabled: model.receiverConfigMessageState == .idle)
                SectionHelp(help: [
                    "Where the receiver listens. Point it at a channel a locator is already "
                    + "on — it does not move the locator. Picking a channel from a scan "
                    + "above applies straight away; typing one here needs Update."
                ])
            }

            // What is known to be on the channel being typed. The scans already gathered
            // this; without it the manual field is the only control on this screen that
            // does not know the band it is pointing at, and typing a number that another
            // rocket is using is exactly the mistake it invites.
            //
            // Only while a change is staged. The note describes what you would be
            // pointing at, so with nothing staged there is nothing to describe — and
            // "Twist 0 is on channel 34" while sitting on 34, connected to Twist 0, is
            // just the status panel read back as though it were news.
            if receiverChannelChanged, let who = occupant(of: stagedReceiverChannel) {
                ChannelNote("\(who) was last heard on channel \(stagedReceiverChannel).",
                            SPColor.onSurfaceVariant)
            }

            ApplyRow(enabled: receiverChannelChanged
                              && model.receiverConfigMessageState == .idle,
                     messageState: model.receiverConfigMessageState) {
                receiverChannelEdited = false
                // The same call the two pick buttons make. It builds the message from the
                // last read-back and changes only the channel — the receiver's name lives
                // on Receiver Settings and rides in this same message, so sending a
                // locally-staged copy of the whole struct would let this screen quietly
                // revert a rename made over there.
                model.pointReceiverAtChannel(stagedReceiverChannel)
            }
        }
    }

    /// Only offered when a locator is connected: this is a locator-directed command
    /// (ADR-0020), so with nothing connected there is no locator to address and the send
    /// would be refused anyway.
    private var locatorChannelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 8)

            HStack(alignment: .center) {
                ConfigIntRow(title: "Locator channel",
                             value: Binding(get: { stagedLocatorChannel },
                                            set: { stagedLocatorChannel = $0
                                                   locatorChannelEdited = true }),
                             range: ReceiverConfig.channelRange,
                             enabled: model.locatorConfigMessageState == .idle)
                SectionHelp(help: [
                    "Moves the connected locator, and the receiver follows it "
                    + "automatically. Use this when the channel is chosen for you; "
                    + "otherwise let the scan pick one."
                ])
            }

            // Gated on a staged change, because the warning is a claim about a MOVE.
            // Ungated it fired on the channel the locator is already using, telling the
            // user that staying put would collide with themselves — and it was right
            // about the occupancy and wrong about everything else.
            if locatorChannelChanged, let who = occupant(of: stagedLocatorChannel) {
                ChannelNote("\(who) is on channel \(stagedLocatorChannel) — moving here "
                            + "would put two locators on one channel.", SPColor.error)
            }

            ApplyRow(enabled: locatorChannelChanged
                              && model.locatorConfigMessageState == .idle,
                     messageState: model.locatorConfigMessageState) {
                locatorChannelEdited = false
                // The same call the survey's "Move here" makes, deliberately: one
                // mechanism with two entry points rather than a second path to the same
                // wire message. It carries the ADR-0011 confirm and revert-on-failure
                // cycle, and lights the progress banner above.
                model.moveLocatorToChannel(stagedLocatorChannel)
            }
        }
    }

    private func occupant(of channel: Int) -> String? {
        ChannelOccupancy.occupant(of: channel,
                                  survey: model.channelSurvey,
                                  search: model.locatorSearch,
                                  excludeLocatorId: model.connectedLocatorId,
                                  labelOf: { model.storedLabel(for: $0) })
    }

    /// Android formats the id as `%08X`, and it is worth matching exactly: this is the
    /// number a user reads out to someone else on the flight line.
    private static func hex(_ id: UInt32) -> String { String(format: "%08X", id) }
}

/// Per-control apply button. Each device acknowledges differently, so each gets its own
/// button and its own state rather than one that averages the two.
struct ApplyRow: View {
    let enabled: Bool
    let messageState: ConfigMessageState
    let onApply: () -> Void

    var body: some View {
        HStack {
            Button(messageState.buttonLabel, action: onApply)
                .buttonStyle(.materialFilled)
                .disabled(!enabled)
            Spacer()
        }
        .padding(.top, 4)
    }
}

/// A short line under a control: a verdict, a refusal, or who is on a channel.
struct ChannelNote: View {
    let text: String
    let color: Color

    init(_ text: String, _ color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(SPFont.labelSmall)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

/// "Find a locator" — the candidate-channel search (ADR-0029, #33 follow-up to ADR-0019).
///
/// Shaped by what a dwell costs. Each channel takes a full broadcast period to rule out,
/// so the default run is a handful of channels the locator is actually likely to be on,
/// and the whole band is offered only after those miss. The channel list is shown before
/// the run starts for the same reason: the user should see that this is seconds of work,
/// not a black box.
struct LocatorSearchSection: View {
    let run: LocatorSearch.Run?
    /// Only ever read to put a name against an id, and to fill the target picker.
    let knownLocators: [(id: UInt32, label: String)]
    @Binding var targetId: UInt32?
    let candidates: [Int]
    let enabled: Bool
    let currentChannel: Int
    let connectedLocatorId: UInt32?
    /// Whether a hit's Connect can act. False while a receiver change is already in
    /// flight — the send would be refused, so the button must not look live.
    var canConnect: Bool = true
    let onSearch: ([Int]) -> Void
    let onCancel: () -> Void
    let onPick: (Int) -> Void

    /// Width of the "Looking for" field and its menu. Sized for the longest locator name
    /// likely to be seen rather than for the widest possible one: a name that overruns
    /// truncates in the field and still reads in full in the open menu.
    private static let targetFieldWidth: CGFloat = 200

    /// Width of the trailing Connect / Connected slot on a hit row. Wide enough for
    /// either label plus a button's content padding, so both start at the same x and the
    /// rows form a column.
    private static let actionSlotWidth: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Find a locator")
                    .font(SPFont.titleMedium)
                    .foregroundStyle(SPColor.onBackground)
                SectionHelp(help: [
                    "Listens on the channels your locators were last seen on. Use this "
                    + "when a locator is powered up but nothing is coming through.",
                    "Search all 64 channels appears once a shorter search has finished. It "
                    + "sweeps the whole band — up to about 90 seconds, during which the "
                    + "receiver hears nothing, and less when it finds locators along the "
                    + "way, since it moves on as soon as a channel answers — and is "
                    + "worth it when the locator is not on any channel the app knows to "
                    + "try, or when you are looking for one it has never met.",
                    "Connecting points the receiver at that channel, and takes effect "
                    + "straight away. Your locator stays where it is, and you will be "
                    + "asked for its password if the app does not know it yet.",
                    "Names and channels here come straight off the air and are not "
                    + "password-checked. Recognition happens as usual once the receiver is "
                    + "pointed at the channel.",
                ])
            }

            targetPicker
            if run?.running == true { progressRow } else { searchButtons }
            hits
            verdict
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    }

    /// Targeting is an accelerator, not a requirement: with a target the receiver stops on
    /// the first frame from it, usually after one dwell. Without one the run is a census,
    /// which is what finds a locator the app has never met.
    @ViewBuilder private var targetPicker: some View {
        if !knownLocators.isEmpty {
            HStack {
                Text("Looking for")
                    .font(SPFont.bodyMedium)
                    .foregroundStyle(SPColor.onBackground)
                    .padding(.trailing, 8)
                // The house picker shape — a control showing the CURRENT VALUE with a
                // chevron, matching Android's `ExposedDropdownMenuBox` (which replaced a
                // bare text button there for the same reason: the value is exactly what
                // the user needs to check before starting a search that behaves
                // differently depending on it).
                Menu {
                    Button("Any locator") { targetId = nil }
                    ForEach(knownLocators, id: \.id) { entry in
                        Button(entry.label) { targetId = entry.id }
                    }
                } label: {
                    HStack {
                        Text(targetLabel)
                            .font(SPFont.bodyLarge)
                            .foregroundStyle(SPColor.onSurface)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12))
                            .foregroundStyle(SPColor.onSurfaceVariant)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: Self.targetFieldWidth, height: 44, alignment: .leading)
                    .background(SPColor.surfaceContainerHighest,
                                in: RoundedRectangle(cornerRadius: 4))
                }
                .disabled(!enabled)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
    }

    private var targetLabel: String {
        guard let targetId,
              let entry = knownLocators.first(where: { $0.id == targetId })
        else { return "Any locator" }
        return entry.label
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ProgressView(value: run?.fraction ?? 0)
                    .padding(.trailing, 8)
                Button("Stop", action: onCancel)
                    .buttonStyle(.materialText)
            }
            .padding(.top, 8)

            ChannelNote(run?.wholeBand == true
                        ? "Listening on channel \(max(run?.searched ?? 1, 1)) of "
                          + "\(run?.total ?? 0) — a full sweep takes up to about 90 seconds."
                        : "Listening on channel \(max(run?.searched ?? 1, 1)) of "
                          + "\(run?.total ?? 0)…",
                        SPColor.onSurfaceVariant)
        }
    }

    /// Both searches side by side, because they are the same decision at two scales — try
    /// the likely channels, or try everything — and stacking them made the second read as
    /// a consequence of the first rather than an alternative to it. Widening only appears
    /// once a short run has completed; the help behind the section's "i" says so.
    ///
    /// A wrapping row, not a fixed one: "Search 6 channels" and "Search all 64 channels"
    /// together are within a few points of a phone's usable width at the default type
    /// size, and past it at a larger one — so the second drops to its own line only when
    /// it genuinely does not fit.
    private var searchButtons: some View {
        WrappingHStack(spacing: 8, lineSpacing: 4) {
            Button("Search \(candidates.count) channels") { onSearch(candidates) }
                .buttonStyle(.materialFilled)
                .disabled(!enabled)
            if run?.canWiden == true {
                Button("Search all 64 channels") { onSearch([]) }
                    .buttonStyle(.materialFilled)
                    .disabled(!enabled)
            }
        }
        .padding(.top, 4)
    }

    /// Hits appear as they arrive, including mid-run: on a targeted search the run ends
    /// the moment one is found, and on a census the user should not have to wait out 63
    /// more channels to see the first answer.
    @ViewBuilder private var hits: some View {
        if let run {
            ForEach(Array(run.hits.enumerated()), id: \.offset) { _, hit in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(hitTitle(hit))
                            .font(SPFont.bodyMedium)
                            .foregroundStyle(SPColor.onBackground)
                        // Both numbers, in the status panel's format and colours. Neither
                        // decides alone: a locator a few feet from the receiver is heard
                        // on channels it is nowhere near and reads STRONG, and SNR is what
                        // separates that artifact from a genuine occupant. With the same
                        // locator reported on two channels, this row is what tells you
                        // which one to point at.
                        HStack(spacing: 0) {
                            Text("\(hit.rssi) dBm")
                                .font(SPFont.labelSmall)
                                .foregroundStyle(RssiBand.color(hit.rssi))
                            Text("  ").font(SPFont.labelSmall)
                            Text("SNR \(hit.snr) dB")
                                .font(SPFont.labelSmall)
                                .foregroundStyle(SnrBand.color(hit.snr))
                            // One locator cannot be on two channels. When it is reported
                            // on several, all but the strongest are FLAGGED rather than
                            // hidden: the reading is real, it is the CHANNEL attribution
                            // that is doubtful, and the numbers beside it are what let the
                            // user check that judgement instead of taking it on trust.
                            if run.suspectChannels.contains(hit.channel) {
                                Text("  ").font(SPFont.labelSmall)
                                Text("· likely false hit")
                                    .font(SPFont.labelSmall)
                                    .foregroundStyle(SPColor.error)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // The receiver's own channel is the acknowledgement: it is read back
                    // from the device (ReceiverInfo, or the next broadcast), so this flips
                    // when the move has actually landed rather than when it was requested.
                    //
                    // Channel AND identity — see `Hit.connectedOn`. Identity alone marked
                    // every row for one locator as Connected, because a near-field
                    // locator's several hits all carry the same id, which left no way to
                    // reach the real channel from the false one.
                    ZStack {
                        if hit.connectedOn(currentChannel: currentChannel,
                                           connectedLocatorId: connectedLocatorId) {
                            Text("Connected")
                                .font(SPFont.labelLarge)
                                .foregroundStyle(SPColor.onSurfaceVariant)
                                .multilineTextAlignment(.center)
                        } else {
                            Button("Connect") { onPick(hit.channel) }
                                .buttonStyle(.materialFilled)
                                .disabled(!canConnect)
                        }
                    }
                    .frame(minWidth: Self.actionSlotWidth)
                }
                .padding(.top, 4)
            }
        }
    }

    /// The name off the air, else the one we stored, else nothing. A `TelemetryData` hit
    /// carries no name at all — an armed locator's frame has no room for one — so the
    /// stored label is what covers that case.
    private func hitTitle(_ hit: LocatorSearch.Hit) -> String {
        let stored = knownLocators.first { $0.id == hit.locatorId && hit.locatorId != 0 }?.label
        let name = hit.deviceName.isEmpty ? stored : hit.deviceName
        guard let name else { return "Unrecognized locator on channel \(hit.channel)" }
        return hit.armed
            ? "\(name) on channel \(hit.channel) — armed"
            : "\(name) on channel \(hit.channel)"
    }

    @ViewBuilder private var verdict: some View {
        if let run, !run.running {
            switch run.status {
            case .refusedArmed:
                ChannelNote("The locator is armed or in flight. Searching would leave the "
                            + "receiver deaf for up to a minute and a half, so it is "
                            + "refused until it lands and disarms.", SPColor.error)
            case .refusedBusy:
                ChannelNote("The receiver is busy — a scan, a flight data transfer, or a "
                            + "command still on its way to the locator. Try again in a "
                            + "moment.", SPColor.error)
            case .cancelled:
                ChannelNote("Search stopped. If you did not stop it, a command you sent to "
                            + "the locator did — the receiver has to be back on your "
                            + "channel to deliver it.", SPColor.onSurfaceVariant)
            case .unknown:
                ChannelNote("No response from the receiver. If its firmware predates "
                            + "locator search, update it — otherwise try again.",
                            SPColor.error)
            default:
                EmptyView()
            }

            // The widen BUTTON sits beside the short search above; what stays here is the
            // reason it appeared. Said only when the run failed at its actual job: a
            // targeted run that turned up somebody else has not succeeded, and naming the
            // locator is clearer than "nothing found" when the screen is showing a hit.
            if run.canWiden {
                if run.missed {
                    let wanted = run.targetLocatorId == 0 ? nil
                        : knownLocators.first { $0.id == run.targetLocatorId }?.label
                    ChannelNote(wanted.map { "\($0) was not on those channels." }
                                ?? "Nothing found on those channels.",
                                SPColor.onSurfaceVariant)
                }
            } else if run.wholeBand && run.hits.isEmpty && run.status == .done {
                ChannelNote("Nothing found anywhere in the band. Check that the locator is "
                            + "powered on and within range.", SPColor.onSurfaceVariant)
            }
        }
    }
}

/// A row that wraps to the next line rather than clipping — Compose's `FlowRow`.
///
/// SwiftUI has no equivalent before iOS 16's `Layout`, which this app can use: the
/// deployment target is 16.0. Two buttons whose combined width depends on a channel count
/// and the user's type size is exactly the case a fixed `HStack` gets wrong, and the
/// failure is a clipped second button rather than an obviously broken layout.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            lineSpacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in layout(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && added > width {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = added
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
