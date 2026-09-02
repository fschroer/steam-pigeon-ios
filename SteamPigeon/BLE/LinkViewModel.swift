import Foundation
import Combine
import CoreLocation

/// Drives the link screen. Deliberately thin: it owns the transport, counts what
/// arrives, and answers health probes. No telemetry parsing yet — the point of this
/// screen is to find out whether the transport works against real hardware.
@MainActor
final class LinkViewModel: ObservableObject {

    @Published private(set) var state: TransportState = .idle {
        didSet {
            // The BLE link, which no longer ends a log but still explains a gap in one.
            // Edge-triggered on ready-ness rather than on every state, as Android's
            // collector is.
            let ready = state == .ready
            if ready != (oldValue == .ready) {
                logFlightEvent(.connectionChanged, detail: String(describing: state))
            }
        }
    }
    @Published private(set) var frameCount = 0
    @Published private(set) var badFrames = 0
    @Published private(set) var countsByType: [MsgType: Int] = [:]
    @Published private(set) var recent: [String] = []
    @Published private(set) var rejects: [String] = []
    @Published private(set) var probesSent = 0
    /// ADR-0033. Outbound chunks that were not cleanly delivered. Zero is the normal
    /// reading; anything else means the link stopped taking writes, and this is the
    /// only place it can be seen — CoreBluetooth discards such a write in silence.
    @Published private(set) var droppedWrites = 0

    /// Latest decoded broadcast from the locator, whichever kind arrived.
    @Published private(set) var prelaunch: PreLaunchData?
    @Published private(set) var telemetry: TelemetryData?
    @Published private(set) var lastLocatorId: UInt32?
    /// When the connected locator last spoke. Drives the marker's trust colour.
    @Published private(set) var lastLocatorMessage: Date?
    /// The locator whose data is on screen. Nothing else reaches the display.
    @Published private(set) var connectedLocatorId: UInt32? {
        didSet {
            // Tracks the last locator actually CONNECTED, not the last value of the
            // property.
            //
            // It goes nil on a dropped BLE link as well as on a deliberate switch, and
            // those must not be treated alike: a dropout mid-recovery is the case this log
            // exists to capture, and ending the file on one would discard the evidence of
            // the thing being investigated. A release is therefore ignored, a reconnect to
            // the same locator resumes the same file, and only a DIFFERENT locator ends it
            // — the only transition after which the rows would describe another airframe.
            guard let id = connectedLocatorId else { return }
            if let last = lastLoggedLocatorId, id != last {
                logFlightEvent(.locatorChanged, detail: "\(last) -> \(id)")
                closeFlightLog(reason: .locatorChanged)
                // Whatever is buffered belongs to the locator being let go of.
                flightLogRecorder.discardPreRoll()
            }
            lastLoggedLocatorId = id
        }
    }
    /// Authorized locators heard while ours holds the connection — shared channel.
    @Published private(set) var conflictingLocatorIds: Set<UInt32> = []
    /// Locators we hold no password for. Cannot be displayed or commanded.
    @Published private(set) var unauthorizedLocatorIds: Set<UInt32> = []

    // MARK: - The conflicting-locator banner (ADR-0006)

    /// The one conflicting locator the banner names, or nil.
    ///
    /// A single id rather than the set above, because the banner offers an ACTION and
    /// an action needs one subject. The set stays: the diagnostics screen lists
    /// everything audible, which is a different question.
    @Published private(set) var conflictLocatorId: UInt32?
    /// When the conflicting locator last spoke — see the hold in `noteConflict`.
    private var lastConflictFrame: Date?
    /// Ids the user has waved away. Remembered, because the conflicting locator keeps
    /// broadcasting at 1 Hz: simply clearing the id put the banner back on the next
    /// packet, which made Dismiss do nothing at all.
    private var dismissedConflictIds: Set<UInt32> = []

    /// The last `PreLaunchData` frame seen, whoever sent it.
    ///
    /// Kept so the banner's Connect can verify against a frame from THAT locator.
    /// `challengeFrame` will not do: it belongs to whichever locator a dialog is open
    /// for, and checking a typed password against another locator's tag is meaningless
    /// at best and a false accept at worst.
    private var lastPrelaunchFrame: [UInt8]?
    private var lastPrelaunchLocatorId: UInt32?
    private var lastPrelaunchDeviceName = ""

    /// How long a conflict stands after its locator goes quiet.
    ///
    /// With two locators on one channel the broadcasts INTERLEAVE, so clearing the
    /// banner whenever a good packet arrives made it flash on and off at the broadcast
    /// rate — visible, but gone again before Connect could be pressed.
    private static let conflictHold: TimeInterval = 8

    /// Seams for the tests. The rules worth pinning are the hold and the dismissal, and
    /// reaching them through `ingest` would mean building authenticated frames — which
    /// would make these tests about ADR-0006 auth rather than about the banner.
    static var conflictHoldForTesting: TimeInterval { conflictHold }
    func noteConflictForTesting(_ id: UInt32) { noteConflict(id) }
    func clearConflictIfStaleForTesting(acceptedId: UInt32, now: Date) {
        clearConflictIfStale(acceptedId: acceptedId, now: now)
    }

    private func noteConflict(_ id: UInt32) {
        guard !dismissedConflictIds.contains(id) else { return }
        conflictLocatorId = id
        lastConflictFrame = Date()
    }

    /// Clear the banner when OUR locator is heard — but only if it is the one named, or
    /// the named one has gone quiet. See `conflictHold`.
    private func clearConflictIfStale(acceptedId: UInt32, now: Date = Date()) {
        if conflictLocatorId == acceptedId {
            conflictLocatorId = nil
        } else if let last = lastConflictFrame, now.timeIntervalSince(last) >= Self.conflictHold {
            conflictLocatorId = nil
        }
    }

    /// Wave the banner away, and keep it away.
    func dismissConflict() {
        if let id = conflictLocatorId { dismissedConflictIds.insert(id) }
        conflictLocatorId = nil
    }

    /// Re-entering Receiver Settings is the user asking to see conflicts again, so a
    /// dismissal from a previous visit does not persist.
    func resetConflictDismissals() { dismissedConflictIds.removeAll() }

    /// The banner's Connect: switch to the conflicting locator, or ask for its password.
    ///
    /// Only acts on a frame from THAT locator. Armed locators raise conflicts too, and
    /// an armed stranger is only connectable once it disarms and broadcasts its identity
    /// and name — which is also the only state in which connecting is useful.
    func requestConnectToConflict() {
        guard let id = conflictLocatorId, id != connectedLocatorId,
              let frame = lastPrelaunchFrame, lastPrelaunchLocatorId == id else { return }

        policy.reconsider(id)
        if gate.isAuthorized(frame: frame, locatorId: id,
                             baseSize: WireProtocol.prelaunchBaseStructSize) {
            // Switch now. The displayed readouts still belong to the old locator until
            // this one's next broadcast lands, at most one 1 Hz period away.
            switchTo(id)
            conflictLocatorId = nil
            return
        }
        challengeFrame = frame
        challenge = LocatorChallenge(locatorId: id, deviceName: lastPrelaunchDeviceName)
    }

    /// ADR-0006 recognition gate. Open locators authenticate unconditionally, so an
    /// unprovisioned locator works with no prompt — the backward-compatibility
    /// guarantee. Passwords are not enterable yet; that needs the challenge dialog.
    private var gate = LocatorGate()

    /// The open password prompt, if any (ADR-0006 Decision 6).
    @Published var challenge: LocatorChallenge?

    private var policy = ChallengePolicy()
    private var store: KnownLocatorStore
    /// The most recent frame from the challenged locator, kept fresh while the dialog
    /// is open so the password is checked against current bytes rather than a stale
    /// frame whose fields have since moved on.
    private var challengeFrame: [UInt8]?

    /// The phone's own position — the other end of every quoted vector.
    let phone = PhoneLocation()

    /// Distance and bearing to the connected locator, or nil when ADR-0022 says the
    /// app cannot stand behind the figure. Suppressed together, because both come out
    /// of one vector: a rejected position aims a bearing just as wrongly.
    @Published private(set) var vector: LocatorVector?
    /// Why the vector is missing, when it is — so the screen can say something more
    /// useful than a blank.
    @Published private(set) var vectorSuppressedReason: String?

    private var plausibility = DistancePlausibility()

    /// Quietest idle floor seen this session — the baseline the ADR-0019 "risen"
    /// test measures against. Relative rather than absolute because SX126x RSSI near
    /// the noise floor is uncalibrated and varies unit to unit.
    private var quietestFloor = LinkQuality.noiseFloorUnknown
    /// When a broadcast from a locator OTHER than ours last arrived. A foreign id is
    /// not evidence of occupancy, it IS occupancy — decoded and identified.
    private var lastForeignBroadcast: Date?
    /// Gap detection: a missed broadcast means the channel is costing us packets.
    private var lastAcceptedBroadcast: Date?
    private var lastLossy: Date?

    /// The classified link verdict, or nil when there is nothing to say.
    @Published private(set) var linkVerdict: LinkQuality.Verdict = .normal

    // MARK: - Receiver-sourced messages

    /// The receiver's own channel, name and channel status.
    ///
    /// Its `noiseFloor` feeds the link classifier through `pollChannel` — ADR-0019
    /// wants this reading specifically because it is the only one that arrives during
    /// locator silence.
    @Published private(set) var receiverInfo: ReceiverInfo?
    /// Locator and receiver firmware versions.
    @Published private(set) var versionInfo: VersionInfo?
    /// The last band sweep, already ranked.
    @Published private(set) var channelSurvey: ChannelSurvey.Result?
    /// True between asking for a sweep and hearing back. The receiver goes deaf for
    /// about a second, so silence needs to read as "working", not as a hang.
    @Published private(set) var surveyInProgress = false

    /// The receiver's configuration as it is believed to be RIGHT NOW.
    ///
    /// Fed from two places, because the receiver reports itself two ways: `ReceiverInfo`
    /// answers a direct question, and every `PreLaunchData` echoes the receiver's own
    /// channel and name in passing. The second is what makes the settings screen
    /// correct without asking, and what confirms a channel change.
    @Published private(set) var remoteReceiverConfig = ReceiverConfig() {
        didSet {
            guard remoteReceiverConfig.channel != oldValue.channel else { return }
            logFlightEvent(.receiverChannelChanged,
                           detail: "\(oldValue.channel) -> \(remoteReceiverConfig.channel)")
            // Past this point the rows describe a different piece of sky.
            closeFlightLog(reason: .receiverChannelChanged)
            flightLogRecorder.discardPreRoll()
        }
    }
    @Published private(set) var receiverConfigMessageState: ConfigMessageState = .idle

    /// The BLE device name of the receiver we are connected to, if any. Refreshed on
    /// every transport state change, since the GAP name can resolve after connecting.
    @Published private(set) var connectedReceiverName: String?

    /// What to call the receiver, in Android's order (`FlightMapScreen.kt`):
    /// `receiverDevice?.name?.takeIf { it.isNotEmpty() } ?: receiverConfig.deviceName`.
    ///
    /// The BLE name comes FIRST, and that is the whole point: the configured name is
    /// learned from `PreLaunchData` (or from a `ReceiverInfo` probe, which only fires
    /// during silence), so with an armed locator broadcasting there is nothing to learn
    /// it from and the row fell through to "Connected".
    var receiverDisplayName: String? {
        Self.receiverDisplayName(bleName: connectedReceiverName,
                                 configuredName: remoteReceiverConfig.deviceName)
    }

    /// Static so the order can be tested without a radio.
    static func receiverDisplayName(bleName: String?, configuredName: String) -> String? {
        if let n = bleName, !n.isEmpty { return n }
        return configuredName.isEmpty ? nil : configuredName
    }

    // MARK: - Locator channel move (ADR-0011)

    /// What the locator is believed to hold, rebuilt from every recognised broadcast.
    @Published private(set) var remoteLocatorConfig = LocatorConfig()
    @Published private(set) var locatorConfigMessageState: ConfigMessageState = .idle
    /// The channel a move is aiming at, while one is in flight or has just finished.
    @Published private(set) var pendingChannelMove: Int?

    /// The channel the BANNER is describing. Deliberately a separate value from
    /// `pendingChannelMove`, and the separation is load-bearing: the pending channel is
    /// what the ADR-0029 search looks on after a failed move, so dismissing the message
    /// used to throw away the one channel worth searching. Conflating the two also made a
    /// *successful* move clear its own "Now on channel N" in the same instant.
    @Published private(set) var channelMoveBannerChannel: Int?

    /// The terminal state, held so the banner outlives the 2 s `.idle` reset. The outcome
    /// of a cycle that can run ~23 s was legible for two.
    @Published private(set) var channelMoveResult: ConfigMessageState?

    /// What the probe established, which is what picks the sentence. Three endings share
    /// `.notAcknowledged` and leave the hardware in different places.
    @Published private(set) var channelMoveOutcome: ChannelMove.Verdict?

    /// The receiver's transmit receipt for the pending move — a `ReceiverInfo` carrying
    /// the new channel, which proves the forward actually transmitted.
    ///
    /// **Latched: only the FIRST match may re-base the confirm window.** The channel watch
    /// polls `ReceiverInfo` every 2 s while the locator is silent, which is exactly the
    /// state an unconfirmed move is in — so every reply matched, each pushed the deadline
    /// out 5 s, and 2 s < 5 s meant the window never closed. Banner stuck on "Moving to
    /// channel N…", probe never ran, receiver left on the new channel with the locator on
    /// the old one. A lost locator, reintroduced by the fix for lost locators.
    ///
    /// Used ONLY to re-base, never to short-circuit: its absence is ambiguous against a
    /// receiver predating it.
    private var channelMoveReceipt: Date?

    /// The locator the pending move was addressed to, captured when it was sent. The
    /// probe attributes its hits with this: an unattributed hit cannot be evidence, and a
    /// *different* locator's hit on the new channel must never read as confirmation.
    private var channelMoveLocatorId: UInt32?

    func clearPendingChannelMove() { pendingChannelMove = nil }

    /// Dismiss hides the MESSAGE, not the staged channel — see `channelMoveBannerChannel`.
    func dismissChannelMoveBanner() {
        channelMoveBannerChannel = nil
        channelMoveResult = nil
    }

    /// Android's `CONFIG_CONFIRM_WINDOW_MS`.
    private static let configConfirmWindow: TimeInterval = 5
    /// How long to wait for a probe run's terminator (`CHANNEL_PROBE_TIMEOUT_MS`).
    private static let channelProbeTimeout: TimeInterval = 20
    /// Sized to outlast the receiver's `kPendingTxStaleMs` (10 s) dropping the queued
    /// command that refuses our probe (`CHANNEL_PROBE_REFUSED_RETRY_MS`).
    private static let channelProbeRefusedRetry: TimeInterval = 6

    /// Put the survey away once a channel has been chosen from it.
    ///
    /// The ranking described the band BEFORE the move, so leaving it up next to a
    /// "now on channel N" message invites a second pick against a picture that is now
    /// out of date — and on the receiver-only path the staged channel it recommended
    /// has already been taken. Android clears it on either branch of the pick.
    func clearChannelSurvey() { channelSurvey = nil }

    /// Seam for the tests: a real result only arrives from a receiver.
    func setChannelSurveyForTesting(_ r: ChannelSurvey.Result) { channelSurvey = r }

    /// Move the locator — and therefore the whole system — to `channel`.
    ///
    /// **This retunes a live locator.** ADR-0011: the request goes out on the OLD
    /// channel, the locator applies it at runtime and its next broadcast comes back on
    /// the NEW one, and the receiver follows only after its forward has finished
    /// transmitting. There is no acknowledgement message — confirmation is the
    /// resumption of broadcasts carrying the new channel (invariant 3).
    ///
    /// Sending the whole settings struct is the design, not an accident, which is why
    /// ADR-0020's target matters so much here: an unaddressed one would rewrite a
    /// bystander's pyro configuration.
    func moveLocatorToChannel(_ channel: Int) {
        pendingChannelMove = channel
        channelMoveBannerChannel = channel
        channelMoveResult = nil
        channelMoveOutcome = nil
        channelMoveReceipt = nil
        channelMoveLocatorId = connectedLocatorId
        var target = remoteLocatorConfig
        target.loraChannel = channel
        changeLocatorConfig(target)
    }

    /// Send a locator configuration change and wait for the locator to confirm it.
    ///
    /// **The whole settings struct goes every time** — that is the wire format, and it
    /// is why ADR-0020's target is enforced in the type system: an unaddressed one
    /// rewrote a bystander's deployment modes, delays and altitudes.
    ///
    /// A channel change is the same message with the recovery path attached, because a
    /// channel change is the only one that can leave the link split (ADR-0011).
    func changeLocatorConfig(_ target: LocatorConfig) {
        guard let id = connectedLocatorId, gate.mayCommand(id) else { return }

        // Captured BEFORE polling, while remoteLocatorConfig still reflects the channel
        // the last broadcast arrived on — the one to fall back to.
        let oldChannel = remoteLocatorConfig.loraChannel
        let channel = target.loraChannel

        locatorConfigMessageState = .sendRequested
        guard let msg = OutboundMessage.locatorDirected(.locatorCfgChgRequest,
                                                        targetLocatorId: id,
                                                        payload: target.payload) else {
            locatorConfigMessageState = .sendFailure
            return
        }
        // The RESULT is the state, not the fact that a call was made. `send` returns
        // false when the peripheral, the write characteristic or the `.ready` state is
        // missing — nothing left the phone. Reporting that as `.sent` made the failure
        // invisible for five seconds and then surfaced it as a read-back timeout, which
        // names the wrong cause: "the receiver did not acknowledge" rather than "nothing
        // was sent". Android has always read the result here
        // (`RocketViewModel.moveLocatorToChannel`).
        locatorConfigMessageState = transport.send(msg) ? .sent : .sendFailure

        Task { @MainActor in
            if await waitForLocatorConfig(target) {
                locatorConfigMessageState = .ackUpdated
            } else if locatorConfigMessageState == .sendFailure {
                // Nothing left the phone, so the receiver never switched and there is
                // nothing to recover. Leave the failure standing.
            } else if channel != oldChannel {
                locatorConfigMessageState =
                    await resolveChannelMove(target: target, oldChannel: oldChannel)
                    ? .ackUpdated : .notAcknowledged
            } else if locatorConfigMessageState.isInFlight {
                locatorConfigMessageState = .notAcknowledged
            }

            if locatorConfigMessageState == .ackUpdated, channel != oldChannel {
                // Confirmed, so it is no longer a move "staged but never confirmed" and
                // has no business in the ADR-0029 search candidates. An unconfirmed one is
                // deliberately kept — that is the channel the locator may have taken
                // alone, and it is the whole reason a search after a failed move looks in
                // the right place.
                pendingChannelMove = nil
            }
            // Held for the banner, which must outlive the `.idle` reset below.
            if channel != oldChannel { channelMoveResult = locatorConfigMessageState }
            try? await Task.sleep(for: .seconds(2))
            locatorConfigMessageState = .idle
        }
    }

    /// Poll ~5 s for the locator's config to come back echoed in a broadcast.
    ///
    /// Whole-object equality, as Android uses. It is why the two placeholder fields in
    /// `LocatorConfig` must match Android's exactly: the config this is compared
    /// against is rebuilt from the next broadcast using the same placeholders, and a
    /// different value would never compare equal, so every change would report as
    /// unacknowledged.
    /// The window is RE-BASED by the receiver's transmit receipt rather than merely
    /// started at the BLE write. The receiver cannot forward a command until it sees a
    /// `PreLaunchData` and is 50–700 ms past it, so on a channel dropping broadcasts — the
    /// channel that motivates a move in the first place — the old fixed window was spent
    /// waiting for the command to be transmitted at all, and expired before the locator
    /// had a chance to answer. The noise that justifies the move was starving its
    /// confirmation. See ADR-0011.
    private func waitForLocatorConfig(_ target: LocatorConfig) async -> Bool {
        let started = Date()
        // Absolute ceiling, independent of any re-base. Belt and braces after the
        // repeated-receipt hang: a wait that can be extended must also be one that cannot
        // be extended forever, whatever future code starts feeding it.
        let hardDeadline = started.addingTimeInterval(2 * Self.configConfirmWindow)
        var deadline = started.addingTimeInterval(Self.configConfirmWindow)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if remoteLocatorConfig == target { return true }
            if locatorConfigMessageState == .sendFailure { return false }
            deadline = ChannelMove.confirmDeadline(started: started,
                                                   deadline: deadline,
                                                   receipt: channelMoveReceipt,
                                                   window: Self.configConfirmWindow,
                                                   hardDeadline: hardDeadline)
        }
        return false
    }

    /// Work out what actually happened to an unconfirmed channel move, and act only on
    /// what the receiver can hear (ADR-0011, "revert on evidence, not on silence").
    /// Returns true if the locator ended up on the staged channel.
    ///
    /// **This replaced a revert-on-silence cut, and the difference is the whole point.**
    /// There is no acknowledgement message, so what goes missing on a "failed" move is a
    /// *broadcast* — and two opposite states produce the same silence: the locator missed
    /// the command and stayed behind while the receiver followed (a real split), or
    /// everything moved and the confirmation was late. Reverting is correct for the first
    /// and **manufactures** the split for the second, in the direction that strands the
    /// rocket, because the locator's move is flash-persistent.
    ///
    /// The **sequence** lives in `ChannelMoveRunner` and is pinned by
    /// `ChannelMoveRunnerTests`; this supplies the side effects. It was moved out because
    /// every defect in that sequence — the lost retry, the refusal read as silence, the
    /// single look at silence — was found by hand on an Android bench, for want of any way
    /// to reach it from a test while it sat in here with a transport in scope.
    ///
    /// **None of this is bench-validated on iOS.**
    private func resolveChannelMove(target: LocatorConfig, oldChannel: Int) async -> Bool {
        await ChannelMoveRunner(ops: ChannelMoveLiveOps(model: self, target: target),
                                refusedRetry: Self.channelProbeRefusedRetry)
            .resolve(newChannel: target.loraChannel, oldChannel: oldChannel)
    }

    // MARK: The live side of a channel-move resolution
    //
    // Searches, BLE writes and the two waits. Everything here touches published state,
    // the transport or the clock, which is exactly what the runner is kept free of.

    fileprivate func probeIsRunning() -> Bool { locatorSearch?.running == true }

    /// A **census** over both channels, never a targeted run that stops on the first hit:
    /// a locator a few feet from the receiver decodes on channels it is nowhere near and
    /// the artifact reads as strong (ADR-0029), so the decision has to compare two dwells
    /// rather than trust one. This probe runs while the user is configuring a locator,
    /// which is exactly the range that produces it.
    ///
    /// Reuses the ordinary search flow, so the run is visible in the search section and
    /// cancellable by the same button, and inherits the receiver's own refusals.
    fileprivate func runChannelProbe(newChannel: Int, oldChannel: Int) async
        -> ChannelMoveRunner.ProbeRun? {
        startLocatorSearch(channels: ChannelMove.probeChannels(newChannel: newChannel,
                                                               oldChannel: oldChannel))
        let deadline = Date().addingTimeInterval(Self.channelProbeTimeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if let run = locatorSearch, !run.running {
                return ChannelMoveRunner.ProbeRun(
                    completed: run.status == .done,
                    verdict: ChannelMove.verdict(hits: run.hits,
                                                 locatorId: channelMoveLocatorId,
                                                 newChannel: newChannel,
                                                 oldChannel: oldChannel))
            }
        }
        return nil
    }

    fileprivate func pointReceiverAtForMove(_ channel: Int) {
        guard let back = OutboundMessage.receiverDirected(
            .receiverCfgChgRequest,
            payload: ReceiverConfig(channel: channel,
                                    deviceName: remoteReceiverConfig.deviceName).payload)
        else { return }
        transport.send(back)
    }

    /// Wait for the link to come back on the old channel — on EVIDENCE that a frame was
    /// admitted after we asked, not merely on two readings that say `oldChannel`. Both of
    /// those readings are updated only by a relayed `PreLaunchData`, so after a move whose
    /// confirmation never arrived they were BOTH still reading the old channel: a test on
    /// the two alone passed on its first 100 ms poll having verified nothing, and the
    /// retry then went out to a channel with nothing on it.
    fileprivate func awaitRelinkForMove(oldChannel: Int, since: Date) async -> Bool {
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if ChannelMove.relinked(receiverChannel: remoteReceiverConfig.channel,
                                    locatorChannel: remoteLocatorConfig.loraChannel,
                                    oldChannel: oldChannel,
                                    lastFrame: lastLocatorMessage,
                                    askedAt: since) { return true }
        }
        return false
    }

    fileprivate func resendLocatorConfigForMove(_ target: LocatorConfig) -> Bool {
        guard let id = connectedLocatorId,
              let retry = OutboundMessage.locatorDirected(.locatorCfgChgRequest,
                                                          targetLocatorId: id,
                                                          payload: target.payload),
              transport.send(retry) else { return false }
        locatorConfigMessageState = .sent
        // The retry is a fresh transmission, so it earns a fresh receipt.
        channelMoveReceipt = nil
        return true
    }

    fileprivate func awaitMoveConfirmation(_ target: LocatorConfig) async -> Bool {
        await waitForLocatorConfig(target)
    }

    fileprivate func noteChannelMoveVerdict(_ verdict: ChannelMove.Verdict) {
        channelMoveOutcome = verdict
    }

    /// Latch the receiver's transmit receipt — see `channelMoveReceipt`.
    fileprivate func noteChannelMoveReceipt(channel: Int) {
        if channelMoveReceipt == nil, channel == pendingChannelMove {
            channelMoveReceipt = Date()
        }
    }

    /// Ask the receiver to sweep the band (ADR-0019 tier 3).
    ///
    /// On demand only: a sweep costs about a second of deafness, and the decision it
    /// informs is made once, on the ground.
    func requestChannelSurvey() {
        guard !surveyInProgress else { return }
        channelSurvey = nil
        surveyToken &+= 1
        let token = surveyToken

        guard state == .ready,
              let msg = OutboundMessage.receiverDirected(.channelSurveyRequest) else {
            channelSurvey = ChannelSurvey.failed(homeChannel: remoteReceiverConfig.channel)
            return
        }
        surveyInProgress = true
        transport.send(msg)

        // A receiver whose firmware predates channel scanning never answers, and the
        // sweep itself takes several seconds, so silence has to time out into a stated
        // failure rather than leaving the button reading "Scanning…" for ever.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.surveyTimeout))
            guard surveyInProgress, token == surveyToken else { return }
            surveyInProgress = false
            channelSurvey = ChannelSurvey.failed(homeChannel: remoteReceiverConfig.channel)
        }
    }

    /// Android's `SURVEY_TIMEOUT_MS`.
    private static let surveyTimeout: TimeInterval = 15
    /// Guards the timeout against a later sweep — without it, an old timer could fail a
    /// survey that has since been restarted and answered.
    private var surveyToken: UInt64 = 0

    // MARK: - Locator search (ADR-0029)

    /// The run in progress or just finished; nil means none this session.
    @Published private(set) var locatorSearch: LocatorSearch.Run?

    /// Android's `SEARCH_SILENCE_TIMEOUT_MS`.
    ///
    /// A **silence** timeout, not a run-length one. A whole-band run is up to ~90 s — far
    /// longer than any fixed timeout that would still catch a receiver going quiet — but
    /// it reports every ~1.4 s, so silence between messages is the thing worth watching.
    private static let searchSilenceTimeout: TimeInterval = 8

    private var searchTimeoutTask: Task<Void, Never>?

    /// Channels worth trying for `targetLocatorId`, or for anything at all when it is nil.
    ///
    /// Exposed so the UI can say what it is about to do before it does it — a search is
    /// seconds of deafness per channel, and "I am going to try 4, 12 and 0" is a very
    /// different proposition from an unexplained progress bar.
    func searchCandidates(targetLocatorId: UInt32? = nil) -> [Int] {
        LocatorSearch.candidates(
            currentChannel: remoteReceiverConfig.channel,
            targetChannel: targetLocatorId.flatMap { store.lastChannel(for: $0) },
            // Every other locator this receiver has been tuned to. A receiver shared
            // across several rockets has been on each of their channels at some point,
            // and that history is the whole reason the short list usually wins.
            //
            // Sorted by id so the order is stable across launches: `channelsById` is a
            // dictionary, and an order that reshuffles would change which candidates
            // survive the 16-channel cap from one run to the next.
            knownChannels: store.channelsById
                .filter { $0.key != targetLocatorId }
                .sorted { $0.key < $1.key }
                .map(\.value),
            // A channel a move was staged to but never confirmed: the locator may have
            // taken it while the receiver did not. Falling back to the channel a
            // receiver-only change just left, while that change is still unresolved —
            // nothing has been heard on the new one, so where we came from is the next
            // best guess.
            attemptedChannel: pendingChannelMove
                ?? (awaitingChannelRecognition ? channelChangePreviousChannel : nil))
    }

    /// The name remembered for a locator, or nil if none is.
    ///
    /// Read wherever an id has to be turned into something a user can act on — an
    /// occupied channel, a search hit for an armed locator that carried no name.
    func storedLabel(for locatorId: UInt32) -> String? { store.label(for: locatorId) }

    /// Every locator the app knows anything about, for the search's target picker.
    /// Named where a name is held, hex where only an id is.
    var knownLocatorLabels: [(id: UInt32, label: String)] {
        store.knownIds
            .sorted()
            .map { (id: $0, label: store.label(for: $0) ?? String(format: "%08X", $0)) }
    }

    /// Start a search over `channels`, or over the whole band when it is empty.
    ///
    /// `targetLocatorId` stops the run on the first frame from that locator; 0 makes it a
    /// census of everything on the listed channels. The receiver enforces its own
    /// refusals (armed, in flight, radio busy) — this only avoids sending a request we
    /// already know will be rejected.
    func startLocatorSearch(channels: [Int], targetLocatorId: UInt32 = 0) {
        guard locatorSearch?.running != true else { return }
        let wholeBand = channels.isEmpty

        guard state == .ready,
              let msg = OutboundMessage.locatorSearch(channels: channels,
                                                      targetLocatorId: targetLocatorId) else {
            locatorSearch = LocatorSearch.Run(running: false, status: .unknown,
                                              wholeBand: wholeBand)
            return
        }
        transport.send(msg)
        locatorSearch = LocatorSearch.Run(
            running: true,
            total: wholeBand ? WireProtocol.surveyChannelCount : channels.count,
            wholeBand: wholeBand,
            targetLocatorId: targetLocatorId)
        armSearchTimeout()
    }

    /// Ask the receiver to stop. It answers with a `Cancelled` terminator, so the UI
    /// settles through the same path as a normal ending rather than a local guess.
    func cancelLocatorSearch() {
        guard locatorSearch?.running == true else { return }
        guard let msg = OutboundMessage.cancelLocatorSearch() else {
            // The request did not even go out, so no terminator is coming.
            searchTimeoutTask?.cancel()
            locatorSearch?.running = false
            locatorSearch?.status = .cancelled
            return
        }
        transport.send(msg)
    }

    func clearLocatorSearch() {
        searchTimeoutTask?.cancel()
        locatorSearch = nil
    }

    /// Seam for the tests: a real run only arrives from a receiver.
    func setLocatorSearchForTesting(_ run: LocatorSearch.Run?) { locatorSearch = run }

    /// Drop what the previous visit left on the Communication screen — **except** a scan
    /// that is still running.
    ///
    /// Both halves were learned the hard way on Android. Keeping the results meant
    /// re-entering the screen showed a run from minutes ago as current, and offered the
    /// whole-band sweep on the strength of it; and a stale refusal ("the locator is
    /// armed") sat there after the locator had been disarmed, describing a state that had
    /// since gone away.
    ///
    /// Clearing unconditionally was worse. `onLocatorSearchResult` drops every message
    /// that arrives while the run is nil, so wiping a run in flight orphaned it: the
    /// receiver went on sweeping — deaf, for up to ~90 s — while the app ignored the
    /// stream and the terminator alike, and the search simply appeared to die on leaving
    /// the screen. Anything still running is therefore left exactly as it is.
    func clearScansForNewVisit() {
        if locatorSearch?.running != true { clearLocatorSearch() }
        if !surveyInProgress { clearChannelSurvey() }
    }

    /// Restarted by every streamed message rather than running one timer for the whole
    /// sweep — see `searchSilenceTimeout`.
    private func armSearchTimeout() {
        searchTimeoutTask?.cancel()
        searchTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.searchSilenceTimeout))
            guard !Task.isCancelled, locatorSearch?.running == true else { return }
            locatorSearch?.running = false
            locatorSearch?.status = .unknown
        }
    }

    /// Fold one streamed result into the run.
    ///
    /// A message arriving while `locatorSearch` is nil is dropped — this app did not
    /// start that run, or has been told to forget it.
    private func onLocatorSearchResult(_ msg: LocatorSearchResult) {
        guard var run = locatorSearch else { return }

        if msg.status == .progress {
            armSearchTimeout()
            run.searched = msg.searched
            // Trust the receiver's denominator over the app's: the firmware dedupes and
            // range-checks the list, so it may search fewer channels than were asked for.
            if msg.total > 0 { run.total = msg.total }
            if msg.found {
                run.hits.append(LocatorSearch.Hit(channel: msg.channel,
                                                  locatorId: msg.locatorId,
                                                  deviceName: msg.deviceName,
                                                  rssi: msg.rssi,
                                                  snr: msg.snr,
                                                  armed: msg.armed))
            }
            locatorSearch = run
            return
        }

        // Terminator: the run is over however it ended.
        searchTimeoutTask?.cancel()
        run.running = false
        run.status = msg.status
        locatorSearch = run
    }

    /// Point the receiver at `channel` now.
    ///
    /// The single apply path for a receiver-only channel change: the search's Connect,
    /// the survey's pick when no locator is connected, and the manual field's Update all
    /// land here. On Android they were three call sites doing the same four steps, which
    /// is how one of them came to *stage* the change and leave the user hunting for an
    /// Update button in another section to finish a decision they had already made by
    /// choosing a channel from a list.
    ///
    /// **The message is built from the last read-back**, changing only the channel. The
    /// receiver's name rides in this same message and is edited on Receiver Settings, so
    /// sending a locally-staged copy of the whole struct would let this screen quietly
    /// revert a rename made over there.
    ///
    /// A no-op when the receiver is already there, so a button press cannot start a
    /// confirm cycle that has nothing to confirm.
    /// - Returns: whether the change was actually started. **Callers must not stage the
    ///   channel on a `false`**: the field would then show a channel the app never went
    ///   to, and light an Update button offering to apply it.
    @discardableResult
    func pointReceiverAtChannel(_ channel: Int) -> Bool {
        guard channel != remoteReceiverConfig.channel,
              receiverConfigMessageState == .idle else { return false }
        // **Armed BEFORE the change goes out**, so the first broadcast to arrive on the
        // new channel is recognised, challenged, or reverted. That is what makes
        // applying a pick immediately safe rather than reckless — see
        // `beginChannelChangeRecognition`.
        beginChannelChangeRecognition(previousChannel: remoteReceiverConfig.channel)
        var target = remoteReceiverConfig
        target.channel = channel
        changeReceiverConfig(target)
        return true
    }

    // MARK: - Channel-change recognition (ADR-0011)

    /// True from a deliberate receiver-only channel change until the first broadcast on
    /// the new channel resolves it, one way or another.
    private var awaitingChannelRecognition = false
    /// Where the receiver was, so a cancelled challenge can put it back.
    private var channelChangePreviousChannel = 0

    /// Arm the channel-change flow: the next `PreLaunchData` on the new channel decides
    /// recognition, or raises a password challenge whose cancel reverts to
    /// `previousChannel`.
    ///
    /// **Releases the connection outright**, and that half is not optional. The point of
    /// the change is to go somewhere else, so the first authorized locator heard on the
    /// new channel should claim the slot without waiting out `connectionHold`. Leaving
    /// the old holder in place is what produced the reported failure: the receiver moved
    /// correctly, the old locator went off-channel and silent, and the new one was
    /// refused — as `conflict` for fifteen seconds if it was authorized, and **for ever**
    /// if it was not, because `ChallengePolicy`'s passive trigger only prompts while
    /// nothing is connected. The screen showed no locator at all and every search row
    /// read Connect, which looked like the receiver having been sent to a wrong channel.
    ///
    /// Measurements of the OLD channel say nothing about the new one, so they are
    /// dropped rather than allowed to age out gracefully — they are wrong immediately.
    func beginChannelChangeRecognition(previousChannel: Int) {
        channelChangePreviousChannel = previousChannel
        awaitingChannelRecognition = true

        gate.disconnect()
        connectedLocatorId = nil
        // **The config describes the locator we just let go of.** Reported from the
        // phone 2026-08-29: the Communication screen's Locator channel field read 34
        // while the receiver read 48, and both were real locators on those channels —
        // the field was describing a device the app had already released, on the one
        // screen whose whole job is "which channel am I talking to". It only corrects
        // itself when a `PreLaunchData` from the NEW locator is admitted, so if that
        // locator is never admitted it never corrects at all.
        //
        // `clearLiveReadouts` already does this when the link drops, for the same
        // reason; releasing a connection deliberately is no different.
        remoteLocatorConfig = LocatorConfig()
        // Any prompt still up belongs to the channel we are leaving. Android clears it
        // here too; without this a challenge raised on the old channel could be answered
        // against a locator that is no longer reachable, storing a password for a frame
        // from somewhere the receiver has already left.
        challenge = nil
        challengeFrame = nil
        conflictLocatorId = nil
        lastConflictFrame = nil
        conflictingLocatorIds.removeAll()
        unauthorizedLocatorIds.removeAll()
        lastForeignBroadcast = nil

        quietestFloor = LinkQuality.noiseFloorUnknown
        quietestPolledFloor = LinkQuality.noiseFloorUnknown
        liveNoiseFloor = LinkQuality.noiseFloorUnknown
        lastPacketMeasurement = nil
        lastFloorMeasurement = nil
        floorFromPoll = false
        linkVerdict = .normal
    }

    /// Nothing arrived after a channel change — stop waiting.
    ///
    /// Android defines this and never calls it; here it is the seam the tests use, and
    /// the hook a future "nothing found on the new channel" prompt would hang off.
    func channelChangeRecognitionTimedOut() { awaitingChannelRecognition = false }

    /// Seam for the tests.
    var isAwaitingChannelRecognition: Bool { awaitingChannelRecognition }

    /// Ask the receiver to describe itself. Used on entering Receiver Settings and to
    /// solicit confirmation after a change — `PreLaunchData` may stop arriving entirely
    /// when the channel moves, so this is the only reliable acknowledgement path.
    func requestReceiverInfo() {
        guard let msg = OutboundMessage.receiverDirected(.receiverInfoRequest) else { return }
        transport.send(msg)
    }

    /// Send a receiver configuration change and wait for the receiver to confirm it.
    ///
    /// **Confirmation compares the CHANNEL only.** The receiver echoes its channel back
    /// in `PreLaunchData` but never its name, so the name is accepted optimistically
    /// once the channel matches — there is nothing else to wait for, and waiting for a
    /// value that never arrives would report every successful rename as unacknowledged.
    func changeReceiverConfig(_ config: ReceiverConfig) {
        guard let msg = OutboundMessage.receiverDirected(.receiverCfgChgRequest,
                                                         payload: config.payload) else {
            receiverConfigMessageState = .sendFailure
            return
        }
        receiverConfigMessageState = .sendRequested
        // As in `changeLocatorConfig` above: a write that never left must say so now,
        // not five seconds later as a read-back timeout. Android's
        // `pointReceiverAtChannel` reads `changeReceiverConfig(target) == true`.
        receiverConfigMessageState = transport.send(msg) ? .sent : .sendFailure

        Task { @MainActor in
            // The BLE module is reset as part of a name change, so the link drops and
            // reconnects; a channel change can stop PreLaunchData entirely. Ask
            // directly rather than waiting to be told.
            try? await Task.sleep(for: .milliseconds(300))
            requestReceiverInfo()

            // Android polls 50 × 100 ms. Same five seconds, same cadence.
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                if remoteReceiverConfig.channel == config.channel {
                    remoteReceiverConfig.deviceName = config.deviceName
                    receiverConfigMessageState = .ackUpdated
                    break
                }
                if receiverConfigMessageState == .sendFailure { break }
            }
            if receiverConfigMessageState.isInFlight {
                receiverConfigMessageState = .notAcknowledged
            }
            // Back to Idle so the button is usable again either way.
            try? await Task.sleep(for: .seconds(2))
            receiverConfigMessageState = .idle
        }
    }

    // MARK: - Things only PreLaunchData carries
    //
    // The locator stops broadcasting `PreLaunchData` the moment it is armed and sends
    // `TelemetryData` instead, so ANY field read straight off `prelaunch` keeps
    // reporting whatever was true just before the arm — for the whole flight, with
    // nothing on screen to say it is old. These are held as their own state, updated
    // from BOTH branches, so the stale reading is impossible rather than merely
    // unlikely. Android does the same thing with a separate `padAlert` flow and a
    // `lastPreLaunchDataTime` clock.

    /// ADR-0021 prepped-and-disarmed verdict.
    @Published private(set) var padAlert: PadAlertState = .quiet
    @Published private(set) var padAlertSnoozeMinutes = 0
    /// When `PreLaunchData` last arrived — a different clock from `lastLocatorMessage`,
    /// which telemetry also refreshes.
    @Published private(set) var lastPreLaunchMessage: Date?

    /// Whether the pre-launch-only readouts (the batteries) are current.
    var isPreLaunchFresh: Bool {
        guard let last = lastPreLaunchMessage else { return false }
        return Date().timeIntervalSince(last) < RocketMarkerState.messageTimeout
    }

    // MARK: - Channel measurements
    //
    // The classifier reads whatever the last measurement left behind, so the app has to
    // remember WHEN each was taken and WHICH sampling regime produced it.

    /// The last reported values. `noiseFloor` can be refreshed with no packet at all —
    /// see `pollChannel` — while `rssi`/`snr` cannot, because those describe a packet.
    private var liveRssi = 0
    private var liveSnr = 0
    private var liveNoiseFloor = LinkQuality.noiseFloorUnknown
    private var lastPacketMeasurement: Date?
    private var lastFloorMeasurement: Date?

    /// Whether the live floor came from a `ReceiverInfo` poll rather than a broadcast.
    private var floorFromPoll = false

    /// **Two baselines, never one.** Polled readings come from the receiver's
    /// continuous-sampling regime and read higher than the safe-window figure a
    /// broadcast carries. Feeding both into a shared minimum-keeping baseline made
    /// every polled reading look elevated, permanently — a channel with nothing on it
    /// reported as interference for the rest of the session.
    private var quietestPolledFloor = LinkQuality.noiseFloorUnknown

    private func updateLinkQuality(rssi: Int, snr: Int, noiseFloor: Int, now: Date = Date()) {
        quietestFloor = LinkQuality.updateQuietestFloor(current: quietestFloor, sample: noiseFloor)

        // A gap longer than one broadcast period means at least one was lost.
        if let last = lastAcceptedBroadcast,
           now.timeIntervalSince(last) >= LinkQuality.lossyGap {
            lastLossy = now
        }
        lastAcceptedBroadcast = now

        liveRssi = rssi
        liveSnr = snr
        liveNoiseFloor = noiseFloor
        lastPacketMeasurement = now
        if noiseFloor != LinkQuality.noiseFloorUnknown {
            lastFloorMeasurement = now
            floorFromPoll = false
        }
        reclassifyLink(now: now)
    }

    /// A channel measurement that needed no locator (ADR-0019).
    ///
    /// `ReceiverInfo` is the only message the receiver sends on its own behalf, so this
    /// is the sole floor reading available during locator silence — which is exactly
    /// when "something is sitting on our channel" and "the locator is switched off" are
    /// hardest to tell apart, and the most useful moment to be able to say which.
    ///
    /// **`rssi` and `snr` are deliberately left alone.** No packet arrived, so there is
    /// nothing new to say about them; they age out on their own clock and the
    /// classifier stops trusting them.
    private func pollChannel(noiseFloor: Int, badFrames: UInt8, now: Date = Date()) {
        // Bad frames counted here are loss we can SEE with no locator transmitting at
        // all: something else is on the channel and being destroyed, which is the case
        // the gap-based test cannot distinguish from silence.
        if badFrames > 0 { lastLossy = now }

        guard noiseFloor != LinkQuality.noiseFloorUnknown else { return }
        quietestPolledFloor = LinkQuality.updateQuietestFloor(current: quietestPolledFloor,
                                                              sample: noiseFloor)
        liveNoiseFloor = noiseFloor
        lastFloorMeasurement = now
        floorFromPoll = true
        reclassifyLink(now: now)
    }

    private func fresh(_ at: Date?, _ now: Date) -> Bool {
        guard let at else { return false }
        return now.timeIntervalSince(at) < LinkQuality.staleMeasurement
    }

    private func reclassifyLink(now: Date) {
        let lossy = lastLossy.map { now.timeIntervalSince($0) < LinkQuality.lossMemory } ?? false
        let foreign = lastForeignBroadcast.map {
            now.timeIntervalSince($0) < LinkQuality.lossMemory
        } ?? false

        // A polled floor is judged against a baseline from its OWN regime, and the
        // absolute test is dropped: that threshold is calibrated for the safe-window
        // statistic, and a continuously-sampled peak clears it on a channel with
        // nothing on it whatsoever.
        let fromPoll = floorFromPoll
        linkVerdict = LinkQuality.classify(
            rssi: liveRssi, snr: liveSnr,
            noiseFloor: liveNoiseFloor,
            quietestFloor: fromPoll ? quietestPolledFloor : quietestFloor,
            lossy: lossy, foreignLocator: foreign,
            packetFresh: fresh(lastPacketMeasurement, now),
            floorFresh: fresh(lastFloorMeasurement, now),
            absoluteFloorTrusted: !fromPoll)
    }

    /// Re-judge the link while nothing is arriving.
    ///
    /// Without this the verdict is only ever recomputed by a packet, so a link that
    /// simply stopped kept asserting whatever the last packet said — a locator switched
    /// off went on being reported as a jammed channel indefinitely.
    private func tickLinkQuality(now: Date = Date()) {
        let heardLocator = lastLocatorMessage != nil
        if heardLocator {
            guard let last = lastLocatorMessage,
                  now.timeIntervalSince(last) >= LinkQuality.lossyGap else { return }
            // Only counted as loss when there was a cadence to miss.
            lastLossy = now
        } else {
            // Never heard a locator: the poll is the only thing that knows anything
            // about the channel, so say nothing until it has spoken recently. Being
            // able to report an occupied channel to someone who has switched on and is
            // hearing nothing is the point of the whole polled path.
            guard fresh(lastFloorMeasurement, now) else { return }
        }
        reclassifyLink(now: now)
    }

    /// Keep a live channel measurement coming while the locator is silent.
    ///
    /// The ADR-0012 health watchdog already asks for `ReceiverInfo`, but on a ~10 s
    /// cadence — far longer than a measurement stays fresh — so a floor sourced from it
    /// would be expired for most of its life and the interference note would blink on
    /// and off between probes.
    ///
    /// **Not started at the first missed broadcast**, and the threshold is deliberately
    /// longer than `lossyGap`: a distant rocket routinely drops a broadcast or two, and
    /// while the locator is transmitting at all the packets that DO arrive carry the
    /// floor themselves. Polling through those gaps is not merely redundant — the
    /// receiver's floor is a peak-since-last-report that every reader drains, so an
    /// extra reader shortens the window for the broadcast that follows.
    private func channelWatchTick(now: Date = Date()) {
        guard state == .ready else { return }
        let silent = lastLocatorMessage.map {
            now.timeIntervalSince($0) >= Self.channelWatchSilence
        } ?? true
        guard silent, let msg = OutboundMessage.receiverDirected(.receiverInfoRequest) else { return }
        transport.send(msg)
    }

    // MARK: - App flight log (ADR-0030)
    //
    // Distinct from the recorded track above and from the locator's downloadable archive.
    // The track is where the rocket went; the archive is what the locator measured at
    // 20 Hz. This is what the PHONE saw — the same 1 Hz frames plus the receiver's
    // RSSI/SNR/noise-floor reading of each one, plus what the app decided and said out loud
    // about them. None of that survives the flight anywhere else.

    let flightLogStore = FlightLogStore()
    private lazy var flightLogRecorder = FlightLogRecorder(sink: flightLogStore.makeSink())

    @Published private(set) var flightLogs: [FlightLogFile] = []

    /// The file currently open, or nil. A boolean would have been enough for the banner and
    /// not enough for the list: a log still being written can be shared, and saying so on
    /// the wrong row would be worse than not saying it.
    @Published private(set) var flightLogRecordingName: String?

    // Last values written as events, so each is reported on its edge rather than on every
    // frame that repeats it. A 1 Hz stream would otherwise carry "link quality: Normal"
    // once a second and bury the transition that matters.
    private var loggedFlightState: FlightStates?
    private var loggedLinkQuality: LinkQuality.Verdict?
    private var loggedLandingThisFlight = false
    private var lastLoggedLocatorId: UInt32?

    func refreshFlightLogs() { flightLogs = flightLogStore.list() }

    func deleteFlightLog(_ name: String) {
        flightLogStore.delete(name)
        refreshFlightLogs()
    }

    func readFlightLog(_ name: String) -> FlightLogContents { flightLogStore.read(name) }

    /// Records something the app said aloud. Wired to `FlightSpeech`, which calls this only
    /// when speech actually reached the synthesizer.
    ///
    /// **iOS needed no `Announcer` facade.** Android built one because nineteen call sites
    /// each reached `TextToSpeech.speak` directly, and a rule remembered at each is a rule
    /// missed at the next one added. `FlightSpeech.say` was already that single funnel here
    /// — including the voice-enabled check — so the hook goes there and every present and
    /// future callout is carried by construction.
    func logAnnouncement(_ text: String) { logFlightEvent(.announcement, detail: text) }

    private func logFlightEvent(_ event: LogEvent, detail: String = "",
                                at timestamp: Date = Date()) {
        flightLogRecorder.offer(.event(.init(timestamp: timestamp, event: event,
                                             detail: detail)))
    }

    /// Opens a log for a launch just detected.
    ///
    /// Named for the locator that flew, taken from its own broadcast name: the file has to
    /// identify the airframe months later, and a name held anywhere else can be a locator
    /// the app is no longer connected to.
    private func openFlightLog(at timestamp: Date) {
        let locatorName = remoteLocatorConfig.deviceName
        let header = "Steam Pigeon app flight log"
            + "; locator=\(locatorName.isEmpty ? "unknown" : locatorName)"
            + "; locator_id=\(connectedLocatorId ?? 0)"
            + "; receiver=\(remoteReceiverConfig.deviceName)"
            + "; receiver_channel=\(remoteReceiverConfig.channel)"
            + "; app_version=\(AppVersion.stamp)"
        loggedLandingThisFlight = false
        if flightLogRecorder.onLaunch(at: timestamp, locatorName: locatorName,
                                      header: header) {
            flightLogRecordingName = FlightLog.fileName(locatorName: locatorName,
                                                        at: timestamp,
                                                        zone: flightLogRecorder.timeZone)
            refreshFlightLogs()
        }
    }

    private func closeFlightLog(reason: LogCloseReason, at timestamp: Date = Date()) {
        guard flightLogRecorder.isRecording else { return }
        flightLogRecorder.close(at: timestamp, reason: reason)
        flightLogRecordingName = nil
        refreshFlightLogs()
    }

    /// The app is going away — ADR-0030's `appStopped` close.
    func closeFlightLogForShutdown() { closeFlightLog(reason: .appStopped) }

    /// Logs a pre-launch frame. Called only for the connected locator: a bystander's
    /// broadcasts are not this rocket's flight, and mixing them in would put two airframes
    /// in one file with nothing to tell them apart.
    private func logPrelaunchFrame(_ m: PreLaunchData, at timestamp: Date) {
        noteLoggedLinkQuality(at: timestamp)
        flightLogRecorder.offer(.sample(.init(
            timestamp: timestamp,
            source: .prelaunch,
            latitude: m.latitude,
            longitude: m.longitude,
            aglM: m.altitudeAgl,
            accel: m.accel,
            gyro: m.gyro,
            satellites: Int(m.satellites),
            haccM: m.horizontalAccuracy,
            rssi: Int(m.rssi),
            snr: Int(m.snr),
            noiseFloor: Int(m.noiseFloor),
            badFrames: Int(m.badFrames),
            linkQuality: linkVerdict,
            armed: m.armed,
            deployArmedMask: Int(m.deployStatus),
            padAlert: m.padAlert,
            locatorBatteryMv: Int(m.locatorBatteryMv),
            receiverBatteryMv: Int(m.receiverBatteryMv),
            receiverChannel: Int(m.channel),
            locatorId: m.locatorId)))
    }

    /// Logs a telemetry frame, and the state transitions it carries.
    private func logTelemetryFrame(_ m: TelemetryData, at timestamp: Date) {
        noteLoggedLinkQuality(at: timestamp)
        if loggedFlightState != m.flightState {
            logFlightEvent(.flightStateChanged,
                           detail: "\(loggedFlightState?.logName ?? "unknown") -> "
                                 + "\(m.flightState.logName)",
                           at: timestamp)
            loggedFlightState = m.flightState
        }
        // Landing is an EVENT, not a close. The walk-in to find the rocket is when link
        // quality matters most and is precisely the window nobody can watch, so the log
        // runs on until the locator is disarmed or something else ends it.
        if !loggedLandingThisFlight, m.flightState == .landed {
            loggedLandingThisFlight = true
            logFlightEvent(.landingDetected, detail: "locator reported Landed", at: timestamp)
        }
        // Bit 2 is fired, bit 5 is armed, per channel — the same masks Android builds.
        var firedMask = 0
        var armedMask = 0
        for (i, stats) in m.deploymentChannelStats.prefix(4).enumerated() {
            if stats & 4 == 4 { firedMask |= 1 << i }
            if stats & 32 == 32 { armedMask |= 1 << i }
        }
        flightLogRecorder.offer(.sample(.init(
            timestamp: timestamp,
            source: .telemetry,
            flightState: m.flightState,
            latitude: m.latitude,
            longitude: m.longitude,
            aglM: m.altitudeAgl,
            velNed: m.velocityNed,
            attitude: m.attitude,
            satellites: Int(m.satellites),
            haccM: m.horizontalAccuracy,
            rssi: Int(m.rssi),
            snr: Int(m.snr),
            noiseFloor: Int(m.noiseFloor),
            badFrames: Int(m.badFrames),
            linkQuality: linkVerdict,
            armed: m.armed,
            deployArmedMask: armedMask,
            deployFiredMask: firedMask,
            drogueDetected: m.physicalDeploymentStats & 1 == 1,
            mainDetected: m.physicalDeploymentStats & 2 == 2,
            locatorId: m.locatorId)))
    }

    /// Logs a `ReceiverInfo` poll.
    ///
    /// Worth a row precisely because it arrives when nothing else does: it is the receiver
    /// measuring the channel with the locator silent (ADR-0019), so it is the only evidence
    /// of what a dropout looked like from this end. A gap in the telemetry rows with these
    /// still ticking through it says the channel was quiet; a gap with a raised noise floor
    /// says something else was on it.
    private func logReceiverInfoFrame(_ m: ReceiverInfo, at timestamp: Date) {
        flightLogRecorder.offer(.sample(.init(
            timestamp: timestamp,
            source: .receiverInfo,
            noiseFloor: Int(m.noiseFloor),
            badFrames: Int(m.badFrames),
            receiverChannel: Int(m.channel))))
    }

    private func noteLoggedLinkQuality(at timestamp: Date) {
        guard loggedLinkQuality != linkVerdict else { return }
        logFlightEvent(.linkQualityChanged,
                       detail: "\(loggedLinkQuality?.logName ?? "unknown") -> "
                             + "\(linkVerdict.logName)",
                       at: timestamp)
        loggedLinkQuality = linkVerdict
    }

    // MARK: - Firmware versions

    /// Whether the cached firmware stamps are still trustworthy.
    ///
    /// A peer that drops off the link and comes back may have been reflashed in between,
    /// so both reconnect paths set this: the LoRa link returning (the locator power-cycled
    /// or was reflashed) and a Bluetooth disconnect (the receiver did). Cleared when a
    /// fresh `VersionInfo` lands.
    ///
    /// Deliberately separate from `versionInfo` itself — blanking that on every brief LoRa
    /// dropout would flicker the settings screens, since both hide the row while it is
    /// empty. The stale stamp stays on screen until a newer one replaces it, which is also
    /// why `clearLiveReadouts` leaves the versions alone.
    private var versionInfoStale = true

    /// The previous tick's view of the link, for the rising edge below. Seeded `false`
    /// because this view model is built once, at launch, with the link down — Android
    /// seeds from the live link instead because its version job re-runs on every Activity
    /// recreation, and a `false` seed there would read an already-up link as a rising edge
    /// on each theme or locale change.
    private var linkWasUpForVersion = false

    /// When the last request went out, standing in for Android's `delay(5_000L)` after
    /// each send: this is a tick, so the back-off is a floor between sends rather than a
    /// suspension inside the loop.
    private var lastVersionRequest: Date?

    /// Ask the locator — via the receiver — for both firmware version strings.
    ///
    /// **This is what populates the Firmware row on both settings screens.** Those rows
    /// existed and were permanently hidden, because nothing ever sent the request: the
    /// message type, the parser and the views were all in place and unconnected.
    ///
    /// Locator-directed, so it carries the connected locator's id (ADR-0020) and cannot go
    /// out with nothing connected — the same gate Android's `sendMessage` applies by
    /// refusing any locator-directed message without a `connectedLocatorId`. The receiver
    /// forwards it, the locator answers with its version, and the receiver appends its own
    /// before relaying, which is why one request fills both rows.
    ///
    /// Runs for the app's lifetime rather than stopping on first success: a locator
    /// reflashed mid-session would otherwise keep reporting the version it booted with
    /// until the app was restarted. A rising edge on the link (silent → sending again) is
    /// the reflash signal, since flashing takes the locator off the air. It transmits only
    /// while stale, so the steady state is silent.
    private func versionTick(now: Date = Date()) {
        guard state == .ready else { return }
        let linkUp = lastLocatorMessage.map {
            now.timeIntervalSince($0) < Self.channelWatchSilence
        } ?? false
        if linkUp, !linkWasUpForVersion { versionInfoStale = true }
        linkWasUpForVersion = linkUp

        guard linkUp, versionInfoStale else { return }
        if let last = lastVersionRequest,
           now.timeIntervalSince(last) < Self.versionRetry { return }
        guard let id = connectedLocatorId, gate.mayCommand(id),
              let msg = OutboundMessage.locatorDirected(.versionRequest, targetLocatorId: id)
        else { return }
        if transport.send(msg) { lastVersionRequest = now }
    }

    /// Android's `LINK_LIVENESS_TICK_MS` and `CHANNEL_WATCH_TICK_MS` / `_SILENCE_MS`.
    private static let livenessTick: TimeInterval = 0.5
    private static let channelWatchTick: TimeInterval = 2
    private static let channelWatchSilence: TimeInterval = 5
    /// Android's version loop ticks at 1 s and waits 5 s after each request.
    private static let versionTick: TimeInterval = 1
    private static let versionRetry: TimeInterval = 5

    private var livenessTimer: Timer?
    private var channelWatchTimer: Timer?
    private var versionTimer: Timer?

    private func startLinkTimers() {
        guard livenessTimer == nil else { return }
        livenessTimer = Timer.scheduledTimer(withTimeInterval: Self.livenessTick,
                                             repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLinkQuality() }
        }
        channelWatchTimer = Timer.scheduledTimer(withTimeInterval: Self.channelWatchTick,
                                                 repeats: true) { [weak self] _ in
            Task { @MainActor in self?.channelWatchTick() }
        }
        versionTimer = Timer.scheduledTimer(withTimeInterval: Self.versionTick,
                                            repeats: true) { [weak self] _ in
            Task { @MainActor in self?.versionTick() }
        }
    }

    /// Recorded ground track of the connected locator, oldest first.
    ///
    /// Capped, because at 1 Hz an unbounded array would grow all afternoon. It is NOT
    /// thinned by distance: what keeps the pad from scribbling is that nothing is
    /// recorded before launch at all (`TrackRecording.recordsPathPoint`), and Android's
    /// own dedup test warns that a minimum-separation filter silently swallows the real
    /// slow movement of a descent under canopy.
    @Published private(set) var track: [TrackPoint] = []
    private static let trackMaxPoints = 2_000

    /// What the map draws.
    var trackCoordinates: [CLLocationCoordinate2D] { track.map(\.coordinate) }

    /// Whether new fixes are appended to the track. Defaults **on**, as Android's
    /// `_isFlightPathRecording` does — a flight recorded only if you remembered to
    /// arm the recorder is a flight lost.
    @Published var isRecordingTrack = true

    /// The downloaded archive record as a map path — the fused, GPS-disciplined track.
    /// Empty until a record is transferred, which is what gates the map's source control.
    ///
    /// **A snapshot, deliberately not derived from `flightData.samples`.** That is the
    /// transfer assembly buffer: `beginTransfer()` empties it and `clearFlightProfileData()`
    /// reaches it through `cancelTransfer()` when you navigate back from the chart. Deriving
    /// from it would leave the path empty by the time the map was on screen — and the whole
    /// point of the feature is to load a record and *then* go look at it, which cannot work
    /// if leaving the profile screen discards it.
    ///
    /// So this outlives the chart on purpose. It is replaced when the next record arrives,
    /// and cleared by `resetTrack()`.
    @Published private(set) var archivedTrack: [TrackPoint] = []

    /// Which track the map draws. Live is raw GPS; archived is the EKF solution.
    @Published private(set) var showArchivedPath = false

    func toggleArchivedPath() { showArchivedPath.toggle() }

    /// What the map should draw.
    ///
    /// The archived track **substitutes** for the live one rather than drawing alongside it:
    /// they are the same quantity measured two ways, so overlaying them in the same colour
    /// would read as one noisy path rather than two estimates.
    var mapTrack: [TrackPoint] {
        showArchivedPath && !archivedTrack.isEmpty ? archivedTrack : track
    }

    /// Snapshots the transferred samples as the archived map path.
    ///
    /// **An empty buffer never overwrites the snapshot**, which is Android's
    /// `samples.isNotEmpty()` guard and is load-bearing rather than defensive. This runs
    /// from `publishFlightSamples` on every absorbed packet, and `clearFlightProfileData`
    /// empties the transfer buffer when you leave the chart — so a single late packet
    /// arriving after that would blank the very snapshot the feature exists to keep,
    /// reintroducing the trap one layer down. A *new* record still replaces the old one,
    /// because a new record has samples.
    private func publishArchivedPath(_ samples: [FlightSample]) {
        guard !samples.isEmpty else { return }
        archivedTrack = FlightPathGeometry.archivedPathPoints(samples)
    }

    private var recorder = TrackRecorder()
    private let trackStore = TrackStore()

    /// The map's "start clean" control (Android `resetFlightPath`).
    ///
    /// Resuming recording is part of it: Android re-arms deliberately, because a
    /// cleared track that then refused to draw is indistinguishable from a broken one.
    func resetTrack() {
        track = []
        isRecordingTrack = true
        recorder.reset()
        trackStore.delete()
        // Clear the archived track too, and fall back to live. Reset is the map's "start
        // clean" control, and leaving a downloaded track drawn after it would look like the
        // reset had failed.
        archivedTrack = []
        showArchivedPath = false
    }

    /// Offer one fix to the track.
    ///
    /// The state machine decides whether it is drawn — see `TrackRecording`. Nothing is
    /// recorded on the pad, and recording stops when the flight ends, which is what
    /// keeps GPS noise from scribbling over the spot the user is walking to.
    private func recordTrack(lat: Double, lon: Double, hasFix: Bool,
                             state: FlightStates, altitudeAglM: Float, descentRateMs: Float) {
        let outcome = recorder.observe(state: state, aglM: altitudeAglM,
                                       descentRateMs: descentRateMs)
        if case .newFlight = outcome {
            // Opened BEFORE this frame is logged, so the frame that proved the launch
            // lands after the launch marker rather than in the pre-roll ahead of it.
            // `recordTrack` runs from `updateVector`, which the ingest branches call
            // before they log the sample.
            openFlightLog(at: Date())
        }
        if case .newFlight = outcome {
            // Fall back to the live track. The archived record substitutes for the live path
            // while displayed, so a new flight left on the archived source would draw the
            // old record and none of the flight now in the air. The download itself is kept.
            showArchivedPath = false
        }
        var changed = false
        if case .newFlight = outcome, !track.isEmpty {
            // A new flight left on the old track would draw the last one under the one
            // now in the air.
            track = []
            changed = true
        }

        let records: Bool
        switch outcome {
        case .newFlight(let r): records = r
        case .record:           records = true
        case .skip:             records = false
        }

        if isRecordingTrack, records, hasFix, lat != 0 || lon != 0,
           !TrackRecording.repeatsFix(track.last, latitude: lat, longitude: lon,
                                      altitudeM: altitudeAglM) {
            track.append(TrackPoint(latitude: lat, longitude: lon, altitudeM: altitudeAglM,
                                    timestampMs: Int64(Date().timeIntervalSince1970 * 1000)))
            if track.count > Self.trackMaxPoints {
                track.removeFirst(track.count - Self.trackMaxPoints)
            }
            changed = true
        }
        if changed { trackStore.save(track) }
    }

    /// The connected locator's latest position, if it reported one.
    var rocketCoordinate: CLLocationCoordinate2D? {
        let (lat, lon) = newest(\.latitude, \.latitude).flatMap { lat in
            newest(\.longitude, \.longitude).map { (lat, $0) }
        } ?? (0, 0)
        guard lat != 0 || lon != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Fields BOTH broadcasts carry
    //
    // **Newest wins — not "telemetry if we have any".**
    //
    // Android merges both messages into one `rocketState`, so whichever arrived last
    // owns every field it carries. iOS keeps the two decoded messages side by side,
    // which means the same rule has to be applied where they are READ — and reading
    // `telemetry ?? prelaunch` is a different rule that goes wrong the moment the
    // locator returns to broadcasting `PreLaunchData`, which it does on every disarm
    // and after every landing. `telemetry` is never nil again once a flight has
    // happened, so it shadowed the fresh pre-launch values for the rest of the session
    // — cured only by restarting the app, which is exactly how it was reported.
    //
    // Fields only TELEMETRY carries — flight state, velocity, attitude — are read from
    // `telemetry` directly and deliberately keep their last value: Android's pre-launch
    // branch does not write them either, so a landed rocket goes on reading Landed.
    // Fields only PRE-LAUNCH carries are aged on `isPreLaunchFresh` instead.

    /// Which broadcast arrived most recently.
    private enum LatestBroadcast { case none, preLaunch, telemetry }
    private var latestBroadcast: LatestBroadcast = .none

    /// The value from whichever broadcast arrived last, given where the field lives in
    /// each of them.
    private func newest<T>(_ fromPreLaunch: KeyPath<PreLaunchData, T>,
                           _ fromTelemetry: KeyPath<TelemetryData, T>) -> T? {
        switch latestBroadcast {
        case .telemetry: return telemetry?[keyPath: fromTelemetry] ?? prelaunch?[keyPath: fromPreLaunch]
        case .preLaunch: return prelaunch?[keyPath: fromPreLaunch] ?? telemetry?[keyPath: fromTelemetry]
        case .none:      return nil
        }
    }

    /// Android's `isInFlight`: armed, OR a flight state other than WaitingLaunch.
    ///
    /// Reads `flightState` — the newest broadcast's — and NOT `telemetry?.flightState`.
    /// The retained telemetry frame is the last one ever received, so once a locator
    /// had flown, that reading was `Landed` for the life of the process and the panel
    /// kept the flight layout over a rocket sitting in its box. This is the same trap
    /// `armed` fell into below, and it has the same answer.
    var isInFlight: Bool { armed || flightState != .waitingLaunch }

    /// Both scans are refused by the RECEIVER while the locator is armed or flying
    /// (ADR-0029 decision 7). Exposed so the Communication screen's buttons can go dead
    /// with the reason already on screen, rather than inviting a press whose only outcome
    /// is a refusal — fschroer, 2026-08-30, running bench 4.
    ///
    /// Written to match the receiver's condition exactly rather than reusing `isInFlight`
    /// above, which counts `landed` as flying: the receiver excludes `landed`
    /// deliberately, so a rocket on the ground is refused for being ARMED and not for
    /// flying, and disabling on the stricter rule would grey out a scan the receiver
    /// would have run. The two live next to each other because that is the only way the
    /// difference is visible.
    ///
    /// This is an affordance, **not** enforcement. The receiver's gate is the real one
    /// and stays — app-side gating is soft (ADR-0006 Decision 5), and the refusal text on
    /// each section still renders if a request gets through anyway.
    var locatorArmedOrFlying: Bool {
        armed || (flightState != .waitingLaunch && flightState != .landed)
    }

    /// Flight state from the NEWEST broadcast, for exactly the reason `armed` is.
    ///
    /// A `PreLaunchData` means the locator is disarmed AND at `WaitingLaunch` — the
    /// locator sends it under no other condition (ADR-0021 amendment 2026-09-01,
    /// which is also what made a disarm resume it at all) — so its arrival is the
    /// locator saying it is back on the pad. It is the only thing that ever says so:
    /// flight state rides in `TelemetryData` alone, and the handler below already
    /// trusts this same invariant when it passes `.waitingLaunch` to `updateVector`.
    @Published private(set) var flightState: FlightStates = .waitingLaunch

    /// Armed state from the NEWEST broadcast.
    ///
    /// Not "telemetry if present": telemetry is deliberately retained across a disarm
    /// so speed and attitude survive landing, which made that reading report armed
    /// forever once a locator had ever been armed — and with it, in-flight forever.
    /// A disarmed locator sends PreLaunchData, so the newest packet is the answer.
    @Published private(set) var armed = false {
        didSet {
            // Android clears the pending blink in `LaunchedEffect(armedState)`, beside
            // the arm/disarm announcement: the acknowledgment IS the locator changing
            // what it broadcasts, so the icon settles on its final colour the moment it
            // does rather than blinking out the whole 2 s timeout. The timeout only has
            // to cover a command that is never answered.
            if armed != oldValue {
                armCommandPending = false
                logFlightEvent(.armedStateChanged, detail: armed ? "armed" : "disarmed")
                // Disarming is how a flight is signed off at the pad, and the rows after
                // it are a locator sitting in a box.
                if !armed { closeFlightLog(reason: .disarmed) }
            }
        }
    }

    // MARK: - Commands (ADR-0020: gated on CONNECTED, not merely authorized)

    /// True when an arm/disarm may be sent: a locator is connected and addressable.
    var canSendArmCommand: Bool {
        guard let id = connectedLocatorId else { return false }
        return gate.mayCommand(id) && state == .ready
    }

    /// Toggle the locator's armed state. Addressed to the connected locator, because
    /// an unaddressed Arm reaches every locator on the channel.
    /// Ask the locator to hold the prepped-and-disarmed alert for another step
    /// (ADR-0021 Decision 5).
    ///
    /// A rocket assembled vertically with charges wired is physically identical to one
    /// standing on the pad, so no sensor separates them — this is the operator saying
    /// "still prepping". Locator-directed, so it carries a target like every other
    /// command (ADR-0020): a snooze is a state change on one rocket, and broadcasting
    /// it would quiet every locator on the channel.
    ///
    /// The app asks for a step; the LOCATOR accumulates and clamps to its own ceiling.
    /// Nothing here may make a snooze indefinite — that would be an off switch, and
    /// hands back the forgotten arm the alert exists to catch.
    func snoozePadAlert() {
        guard let id = connectedLocatorId, gate.mayCommand(id) else { return }
        guard let msg = OutboundMessage.locatorDirected(
            .padAlertSnoozeRequest, targetLocatorId: id,
            payload: [UInt8(PadAlertState.snoozeStepMinutes)]) else { return }
        transport.send(msg)
    }

    func toggleArmed() {
        guard let id = connectedLocatorId, gate.mayCommand(id) else { return }

        // Mirror the locator's rule: a disarm is only honoured while the rocket is
        // waiting for launch or has landed. Blocking it here — and SAYING WHY —
        // beats sending a request the locator silently ignores, which reads as the
        // app having done nothing.
        if armed, flightState != .waitingLaunch, flightState != .landed {
            transientMessage = "Can't disarm while the rocket is in flight. Wait until it has landed."
            return
        }

        let type: MsgType = armed ? .disarmRequest : .armRequest
        guard let msg = OutboundMessage.locatorDirected(type, targetLocatorId: id) else { return }
        // Android's `changeLocatorArmedState` sets SendFailure when the write does not
        // go out. iOS carries arm state as `armCommandPending` rather than a message
        // state, so the equivalent is: do not blink for an acknowledgement that cannot
        // come, and say what happened. An arm press that silently does nothing is the
        // worst version of this bug — the user is standing at a pad believing a command
        // is in flight.
        guard transport.send(msg) else {
            transientMessage = "The command could not be sent — the receiver link is down."
            return
        }
        armCommandPending = true
        // The locator answers by changing what it broadcasts; if it never does, stop
        // blinking rather than blinking forever.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            armCommandPending = false
        }
    }

    /// Drop the link and look for receivers again.
    ///
    /// Nothing special left to do: every scan offers the choice now, including the one
    /// at launch, so this is just "start over". It used to have to forget a remembered
    /// receiver first, because the launch scan would otherwise reconnect to it silently
    /// — the behaviour that made a second receiver unreachable.
    func rescan() {
        transport.disconnect()
        discoveredReceivers = []
        transport.startScan()
    }

    /// True while an arm/disarm is in flight — drives the blinking rocket icon.
    @Published private(set) var armCommandPending = false

    /// Receivers found this scan, offered to the user rather than picked for them.
    @Published private(set) var discoveredReceivers: [(id: UUID, name: String)] = []

    /// A message to show and dismiss — the equivalent of Android's Toast.
    @Published var transientMessage: String?

    func selectReceiver(_ id: UUID) {
        transport.connectToDiscovered(id)
        discoveredReceivers = []
    }

    func dismissReceiverPicker() { discoveredReceivers = [] }

    // MARK: - Deployment test (ADR-0027)

    // **The display follows the LOCATOR, never the app's own hope.** Every frame here is
    // unacknowledged: the request that starts a test, and the request that stops one. The
    // countdown arriving is the only evidence a charge is live, and the countdown going
    // quiet is the only evidence a test has ended.
    //
    // Android learned this the expensive way. Pressing cancel used to clear `active`
    // immediately, which gated the countdown handler and made the app deaf to the very
    // countdown still running: the button went back to reading "start" while the locator
    // counted down and fired, and nothing on screen disagreed.

    /// True from the moment a start frame is handed to the radio until the locator has
    /// gone quiet for `deploymentTestSilence`.
    @Published private(set) var deploymentTestActive = false

    /// Seconds the locator last reported. **Written only by the locator's messages and by
    /// the silence watchdog** — there is deliberately no setter, because letting a caller
    /// assert a countdown the locator has not agreed to is the whole failure mode above.
    @Published private(set) var deploymentTestCountdown = 0

    /// True from the moment a cancel frame is sent until the countdown stops. Drives the
    /// "STOPPING…" label, which says the request is out and unanswered — the state the
    /// operator needs to see, rather than a button that has already returned to normal.
    @Published private(set) var deploymentTestCancelPending = false

    private var deploymentTestSilenceTask: Task<Void, Never>?

    /// Android's `DEPLOYMENT_TEST_SILENCE_MS`. Long enough to outlast the 1 Hz countdown
    /// with margin for a dropped frame, short enough that the screen does not claim a
    /// live charge after the locator has stopped talking about one.
    static let deploymentTestSilence: TimeInterval = 3

    // Seams for the tests. The rules worth pinning are the watchdog and "the display
    // follows the locator", and reaching them the real way would mean three-second waits
    // and a live radio — which would make these tests about neither.
    static var deploymentTestSilenceForTesting: TimeInterval { deploymentTestSilence }
    private var silenceInterval: TimeInterval = LinkViewModel.deploymentTestSilence
    func setDeploymentTestSilenceForTesting(_ seconds: TimeInterval) {
        silenceInterval = seconds
    }

    /// Stands in for a start frame having gone out, without one.
    func setDeploymentTestActiveForTesting(_ active: Bool) {
        deploymentTestActive = active
        if active { armDeploymentTestSilence() }
    }

    func ingestForTesting(_ frame: [UInt8]) { ingest(frame) }

    /// What every link loss runs — including the scan that starts a second after launch.
    func clearLiveReadoutsForTesting() { clearLiveReadouts() }

    /// Drives the real snapshot path, samples in, so a test exercises the conversion and
    /// the lifecycle together rather than assigning the result.
    func publishArchivedPathForTesting(_ samples: [FlightSample]) { publishArchivedPath(samples) }

    /// One turn of the firmware-version loop. The real one is a 1 s timer, and what is
    /// worth testing is the rising edge and the back-off, not the scheduler.
    func versionTickForTesting(now: Date = Date()) { versionTick(now: now) }
    var isVersionInfoStaleForTesting: Bool { versionInfoStale }

    /// When the locator was last heard, which is the clock the version loop judges the
    /// link by. A seam because the two intervals in play are both 5 s — the silence
    /// window and the request back-off — so any test of one has to hold the other still,
    /// and `ingest` stamps this with the wall clock.
    func setLastLocatorMessageForTesting(_ date: Date?) { lastLocatorMessage = date }

    /// Fire a channel. Addressed, like every locator-directed command (ADR-0020) — a
    /// broadcast one would fire somebody else's charge.
    func startDeploymentTest(_ option: DeploymentTestOption) {
        guard option != .none else { return }
        if let id = connectedLocatorId, gate.mayCommand(id) {
            send(deploymentTestChannel: option.rawValue, to: id)
        }
        // Marked active **whether or not the frame left the phone**, as Android does. A
        // start frame can be lost on the air just as easily as it can fail to be built,
        // and the two are indistinguishable from here; the watchdog is what recovers from
        // both. Without this the screen would sit resting while a locator that DID hear
        // the frame counted down.
        deploymentTestActive = true
        armDeploymentTestSilence()
    }

    /// Ask the locator to stop. **Changes nothing about the countdown**: the locator
    /// decides when the test is over, and this app finds out by the countdown stopping.
    ///
    /// Pressing repeatedly re-sends, which is what an operator will do anyway and is the
    /// right answer on a link that drops frames.
    func cancelDeploymentTest() {
        if let id = connectedLocatorId, gate.mayCommand(id) {
            send(deploymentTestChannel: DeploymentTestOption.none.rawValue, to: id)
        }
        // Reported pending **even if nothing could be sent**, as Android does. Pressing
        // STOP and seeing nothing change is the worst answer this screen can give: the
        // operator cannot tell a dead link from a button that did not register, and will
        // stand there pressing it. "STOPPING…" says the request is out and unanswered,
        // and the watchdog ends it either way.
        noteDeploymentTestCancelSent()
    }

    /// Record that a cancel frame has just been handed to the radio.
    func noteDeploymentTestCancelSent() {
        guard deploymentTestActive else { return }
        deploymentTestCancelPending = true
        armDeploymentTestSilence()
    }

    /// Leaving the screen cancels a running test, and the state is deliberately NOT
    /// cleared here.
    ///
    /// Clearing it discarded the locator's countdown, so a cancel lost on the way out
    /// left the operator walking off with a live charge and an app that had forgotten
    /// about it — and coming back showed a resting button rather than the test still
    /// counting. Leaving it alone means the countdown is still there if the cancel did
    /// not land, and the watchdog clears everything once the locator really is quiet.
    func leaveDeploymentTest() {
        cancelDeploymentTest()
    }

    private func send(deploymentTestChannel channel: UInt8, to id: UInt32) {
        guard let msg = OutboundMessage.locatorDirected(.deploymentTestRequest,
                                                        targetLocatorId: id,
                                                        payload: [channel]) else { return }
        transport.send(msg)
    }

    /// Restarted by every countdown message, so it fires only once the locator has
    /// genuinely gone quiet. One rule covers all three endings — canceled, fired, link
    /// lost — because from here they are indistinguishable, and all three mean the same
    /// thing for the screen.
    private func armDeploymentTestSilence() {
        deploymentTestSilenceTask?.cancel()
        let interval = silenceInterval
        deploymentTestSilenceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            deploymentTestCancelPending = false
            deploymentTestCountdown = 0
            deploymentTestActive = false
        }
    }


    // MARK: - Flight profiles (ADR-0016; Android `FlightProfilesScreen` + `FlightDataRepository`)

    /// The locator's archive slots, as its last `flightMetadata` frame described them.
    @Published private(set) var flightProfileMetadata: [FlightRecordMetadata] = []
    @Published private(set) var flightProfileMetadataState: ConfigMessageState = .idle

    /// How many times the current fetch has asked the locator for the record list.
    /// Surfaced so a slow fetch reads as "still trying" rather than as a frozen screen.
    @Published private(set) var flightProfileMetadataAttempt = 0

    /// The archive slot being viewed. Also the gate on `flightEvents`: the locator
    /// repeats that frame, and a late one from a previously-selected record would
    /// otherwise mislabel the chart on screen.
    @Published private(set) var flightProfileArchivePosition = 0

    @Published private(set) var flightProfileDataState: ConfigMessageState = .idle

    /// False shows the record list, true shows the chart. One flag rather than a
    /// navigation stack, exactly as Android has it — the locator's transfer state is
    /// what actually changes, and the screen follows it.
    @Published private(set) var flightProfileDataDisplayState = false

    /// Per-record event summary for the profile being viewed. Arrives as its own
    /// `flightEvents` frame just ahead of the sample burst.
    @Published private(set) var flightEvents = FlightEvents()

    /// Samples reassembled so far. Republished as packets land, so the chart draws a
    /// transfer while it is still streaming.
    @Published private(set) var flightSamples: [FlightSample] = []
    @Published private(set) var flightTransferProgress = FlightTransferProgress()

    private let flightData = FlightDataRepository()

    /// Android's `METADATA_RETRY_INITIAL_MS` / `METADATA_RETRY_MAX_MS`. The cap keeps a
    /// long wait refreshing the locator's 30 s metadata-idle timeout, rather than
    /// letting it drop back to Disarmed while the screen is still open.
    private static let metadataRetryInitial: TimeInterval = 3
    private static let metadataRetryMax: TimeInterval = 12

    /// Ask the locator to list its archived flights, and keep asking until it answers.
    ///
    /// Mirrors Android's entry `LaunchedEffect` and `fetchFlightProfileMetadata`
    /// together: reset, then retry with a doubling backoff. **Cancellation is what ends
    /// it** — the screen runs this from a `.task`, which iOS cancels on disappear, the
    /// same way leaving the composable cancels Android's coroutine.
    func fetchFlightProfileMetadata() async {
        // Resuming into an already-loaded chart: a metadata request would send the
        // locator back to MetadataRequested and abort the transfer the user is waiting
        // on, so leave an in-progress load alone.
        guard !flightProfileDataDisplayState else { return }

        flightProfileDataState = .idle
        flightProfileMetadata = []
        flightData.clearMetadata()
        flightProfileMetadataAttempt = 0

        var backoff = Self.metadataRetryInitial
        var attempt = 0

        while !Task.isCancelled {
            // Opening a record takes over the link — see above.
            if flightProfileDataDisplayState { return }

            attempt += 1
            flightProfileMetadataAttempt = attempt
            flightProfileMetadataState = .sendRequested
            let sent = requestFlightProfileMetadata()
            // Don't clobber a response that landed while we were sending.
            if !sent {
                flightProfileMetadataState = .sendFailure
            } else if flightProfileMetadataState == .sendRequested {
                flightProfileMetadataState = .sent
            }

            if await waitForFlightMetadata(timeout: backoff) { return }

            if flightProfileMetadataState == .sent {
                flightProfileMetadataState = .notAcknowledged
            }
            backoff = min(backoff * 2, Self.metadataRetryMax)
        }
    }

    /// Poll for the answer, at the same 100 ms cadence as every other wait here.
    private func waitForFlightMetadata(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if flightProfileMetadataState == .ackUpdated { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return flightProfileMetadataState == .ackUpdated
    }

    /// Ask for the record list. Addressed, like every locator-directed command.
    @discardableResult
    func requestFlightProfileMetadata() -> Bool {
        guard let id = connectedLocatorId, gate.mayCommand(id),
              let msg = OutboundMessage.locatorDirected(.flightMetadataRequest,
                                                        targetLocatorId: id) else { return false }
        // Returns whether the request actually went out. The caller's retry loop reads
        // this to choose between `.sent` and `.sendFailure`, exactly as Android's
        // metadata loop reads `service.requestFlightProfileMetadata()`.
        return transport.send(msg)
    }

    /// Open one archived record: show the chart and start the transfer.
    func openFlightProfile(position: Int) {
        flightProfileArchivePosition = position
        flightProfileDataDisplayState = true
        flightProfileDataState = .sendRequested

        // Clears the receive state and, with it, the drain flag set by a previous
        // cancel — a transfer cannot start while stale packets are still being refused.
        flightData.beginTransfer()
        flightSamples = []
        flightTransferProgress = flightData.progress

        guard let id = connectedLocatorId, gate.mayCommand(id),
              let msg = OutboundMessage.locatorDirected(.flightDataRequest,
                                                        targetLocatorId: id,
                                                        payload: [UInt8(clamping: position)])
        else {
            flightProfileDataState = .sendFailure
            return
        }
        // Android's `getFlightProfileData` branches on the send result the same way.
        flightProfileDataState = transport.send(msg) ? .sent : .sendFailure
    }

    /// Leave the chart for the record list.
    ///
    /// The metadata request is not merely a refresh: it tells the locator we are back
    /// at the list, so it aborts the in-flight transfer immediately instead of bursting
    /// until it times out.
    func returnToFlightProfileList() {
        clearFlightProfileData()
        flightProfileDataState = .idle
        flightProfileDataDisplayState = false
        requestFlightProfileMetadata()
    }

    /// Drop one record's data and refuse anything still arriving for it.
    func clearFlightProfileData() {
        flightEvents = FlightEvents()
        flightData.cancelTransfer()
        flightSamples = []
        flightTransferProgress = flightData.progress
    }

    /// Leaving the screen altogether: tell the locator to return to Disarmed so it
    /// resumes `PreLaunchData`. It is a `DisarmRequest` because that is the message the
    /// locator's flight-profile mode listens for — the rocket is disarmed already.
    func exitFlightProfileMode() {
        flightProfileDataDisplayState = false
        guard let id = connectedLocatorId, gate.mayCommand(id),
              let msg = OutboundMessage.locatorDirected(.disarmRequest,
                                                        targetLocatorId: id) else { return }
        transport.send(msg)
    }

    /// Acknowledge what has arrived so far. The locator sends what the bitmap says is
    /// missing, so a dropped ack costs a retransmit round rather than the transfer.
    private func sendFlightDataAck(_ payload: [UInt8]) {
        guard let id = connectedLocatorId, gate.mayCommand(id),
              let msg = OutboundMessage.locatorDirected(.flightDataAck,
                                                        targetLocatorId: id,
                                                        payload: payload) else { return }
        transport.send(msg)
    }

    /// Republish what the repository holds after a packet is absorbed.
    private func publishFlightSamples() {
        flightSamples = flightData.samples
        publishArchivedPath(flightData.samples)
        flightTransferProgress = flightData.progress
    }


    /// Drop everything that describes a link we no longer have.
    ///
    /// **The recorded track is deliberately NOT in here.** It describes where the rocket
    /// went, not which receiver relayed the fixes, so a lost link says nothing about it —
    /// and this runs on `.scanning`, which the app enters within a second of launching.
    /// The track restored from disk in `init` was therefore wiped before it could be
    /// drawn, and the next recorded point saved the emptied array back over the file:
    /// a track survived being killed exactly until the app was opened again. Android
    /// clears its `_flightPath` in two places only — `resetFlightPath`, the map's own
    /// "start clean" control, and the new-flight branch of the telemetry handler — and
    /// nothing about its connection state touches it.
    private func clearLiveReadouts() {
        prelaunch = nil
        // Receiver-sourced state describes a receiver we are no longer talking to.
        // The versions are the exception: they are a property of the hardware, not of
        // this link, and re-showing them on reconnect beats a blank field. They are
        // marked STALE rather than cleared, so the next link-up re-asks and the row keeps
        // its last value meanwhile instead of flickering — the receiver can only be
        // reflashed across a BLE drop, which the LoRa rising edge cannot see.
        versionInfoStale = true
        linkWasUpForVersion = false
        lastVersionRequest = nil
        receiverInfo = nil
        channelSurvey = nil
        surveyInProgress = false
        remoteLocatorConfig = LocatorConfig()
        pendingChannelMove = nil
        conflictLocatorId = nil
        lastConflictFrame = nil
        lastPrelaunchFrame = nil
        lastPrelaunchLocatorId = nil
        quietestPolledFloor = LinkQuality.noiseFloorUnknown
        liveNoiseFloor = LinkQuality.noiseFloorUnknown
        lastFloorMeasurement = nil
        lastPacketMeasurement = nil
        floorFromPoll = false
        latestBroadcast = .none
        padAlert = .quiet
        padAlertSnoozeMinutes = 0
        lastPreLaunchMessage = nil
        telemetry = nil
        vector = nil
        armed = false
        flightState = .waitingLaunch
        connectedLocatorId = nil
        conflictingLocatorIds.removeAll()
        unauthorizedLocatorIds.removeAll()
        linkVerdict = .normal
        awaitingChannelRecognition = false
        quietestFloor = LinkQuality.noiseFloorUnknown
        lastLocatorMessage = nil
        gate.disconnect()
        plausibility.reset()
    }

    /// ADR-0017 trust state for the drawn position.
    /// Whether the locator has spoken recently enough to describe.
    ///
    /// Android's `lastMessageAge < messageTimeout`, which gates the centre banner: a
    /// banner describing a rocket the app is no longer in contact with is a claim it
    /// cannot make. The stats panel and marker use the same clock.
    var isLocatorFresh: Bool {
        guard let last = lastLocatorMessage else { return false }
        return Date().timeIntervalSince(last) < RocketMarkerState.messageTimeout
    }

    /// Whether a locator's broadcasts are actually arriving, on the same 5 s rule the
    /// channel watchdog uses for "the locator has gone quiet".
    ///
    /// **Deliberately not `isLocatorFresh`**, which is the 2 s freshness the map applies
    /// to a *reading*. This decides whether a whole section of the Communication screen
    /// is on screen, and at 1 Hz a single dropped broadcast would blink it.
    ///
    /// Takes `now` because silence has no event: nothing arrives to trigger a redraw when
    /// the locator stops, so the caller re-evaluates this on a tick.
    func isHearingLocator(now: Date = Date()) -> Bool {
        guard let last = lastLocatorMessage else { return false }
        return now.timeIntervalSince(last) < Self.channelWatchSilence
    }

    var markerState: RocketMarkerState {
        RocketMarkerState.from(
            lastMessageAge: lastLocatorMessage.map { Date().timeIntervalSince($0) } ?? .infinity,
            gpsStatus: telemetry?.gpsStatus ?? prelaunch?.gpsStatus)
    }

    var rocketAccuracyM: Double? {
        newest(\.horizontalAccuracy, \.horizontalAccuracy).map(Double.init)
    }

    /// Per-channel deployment continuity.
    ///
    /// Reported from the phone as channels showing no continuity when one of them had
    /// it, cured by restarting the app — the signature of a stale value winning.
    var deployChannelContinuity: [Bool] {
        newest(\.deployChannelContinuity, \.deployChannelContinuity) ?? []
    }

    var satellites: UInt8? { newest(\.satellites, \.satellites) }
    var gpsStatus: SensorHealth? { newest(\.gpsStatus, \.gpsStatus) }
    var rssi: Int? { newest(\.rssi, \.rssi).map(Int.init) }
    var snr: Int? { newest(\.snr, \.snr).map(Int.init) }
    var altitudeAglM: Float { newest(\.altitudeAgl, \.altitudeAgl) ?? 0 }

    /// Behind `LocatorTransport` rather than the concrete class, so a test can make a
    /// write fail — which is what `send`'s discarded result went unnoticed for.
    private let transport: LocatorTransport
    private let started = Date()

    /// - Parameter defaults: where remembered locators live. Injectable **for the tests
    ///   only**: `UserDefaults.standard` persists across simulator runs, so a test that
    ///   needs an *unauthorized* locator otherwise depends on what an earlier test — or
    ///   an earlier run of the whole suite — happened to store. That is a defect the
    ///   suite can hide rather than report, since the polluted case is the one where the
    ///   locator authenticates and everything looks fine.
    init(defaults: UserDefaults = .standard, transport injected: LocatorTransport? = nil) {
        transport = injected ?? BluetoothTransport()
        store = KnownLocatorStore(defaults: defaults)
        for (id, key) in store.keysById { gate.remember(locatorId: id, passwordKey: key) }
        // A track survives the app being killed, as Android's does. The recorder's own
        // flags deliberately do NOT: `flightStateObserved` starts false so the first
        // packet after a restart cannot be read as a launch and wipe the flight it just
        // rejoined.
        track = trackStore.load()
        transport.onDiscover = { [weak self] peripherals in
            Task { @MainActor in
                guard let self else { return }
                // ALWAYS offer the choice. Android shows its picker whenever
                // discovery finds one or more devices, and silently reconnecting to
                // the receiver used last means someone with two receivers cannot
                // reach the other one without noticing why.
                self.discoveredReceivers = peripherals.map {
                    ($0.identifier, $0.name ?? "Unnamed receiver")
                }
            }
        }
        transport.onStateChange = { [weak self] s in
            Task { @MainActor in
                guard let self else { return }
                self.state = s
                // Readouts describe the link that produced them. Holding them across
                // a disconnect leaves the panel asserting a locator, a battery and a
                // link quality that belong to a receiver we are no longer talking to
                // — during the seconds when the user is waiting to see whether the
                // switch worked, which is exactly when it misleads.
                if s == .disconnected || s == .scanning || s == .connecting {
                    self.clearLiveReadouts()
                }
                // After the readouts are cleared, not before: `clearLiveReadouts` is
                // about the LOCATOR's data, and this is the receiver naming itself.
                self.connectedReceiverName = self.transport.connectedName
            }
        }
        transport.onNameChange = { [weak self] name in
            Task { @MainActor in self?.connectedReceiverName = name }
        }
        transport.onFrame = { [weak self] frame in
            Task { @MainActor in self?.ingest(frame) }
        }
        transport.onBadFrameCount = { [weak self] n in
            Task { @MainActor in self?.badFrames = n }
        }
        transport.onDroppedWrites = { [weak self] n in
            Task { @MainActor in self?.droppedWrites = n }
        }
        transport.onReject = { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                let stamp = String(format: "%7.1fs", Date().timeIntervalSince(self.started))
                self.rejects.insert("\(stamp)  \(r.summary)", at: 0)
                if self.rejects.count > 12 { self.rejects.removeLast() }
            }
        }
        // ADR-0012: the probe must be a message the RECEIVER answers on its own
        // behalf. Anything locator-bound would depend on the locator being powered
        // and in range — the very thing that may legitimately be absent.
        transport.onHealthProbe = { [weak self] in
            guard let msg = OutboundMessage.receiverDirected(.receiverInfoRequest) else { return }
            self?.transport.send(msg)
            Task { @MainActor in self?.probesSent += 1 }
        }
    }

    func start() {
        transport.startScan()
        phone.start()
        startLinkTimers()
    }

    /// Recompute the vector to the connected locator after a new broadcast.
    ///
    /// ADR-0022: the range ceiling applies to every quoted distance whatever the
    /// locator claims about its own fix, and a fixless reading is judged on having
    /// jumped rather than on being fixless.
    private func updateVector(lat: Double, lon: Double, satellites: UInt8,
                              gpsStatus: SensorHealth, state: FlightStates,
                              altitudeAglM: Float, descentRateMs: Float = 0) {
        guard let me = phone.coordinate, phone.hasUsableFix else {
            vector = nil
            vectorSuppressedReason = phone.authorized
                ? "waiting for this phone's GPS fix"
                : "location permission needed for distance and bearing"
            return
        }

        let v = LocatorVector.between(from: (me.latitude, me.longitude),
                                      to: (lat, lon),
                                      altitudeAglM: altitudeAglM)
        let hasFix = DistancePlausibility.hasFix(satellites: satellites, gpsStatus: gpsStatus)
        recordTrack(lat: lat, lon: lon, hasFix: hasFix, state: state,
                    altitudeAglM: altitudeAglM, descentRateMs: descentRateMs)

        if plausibility.accept(distanceM: v.distanceM, hasFix: hasFix, state: state) != nil {
            vector = v
            // ADR-0023 gives ADR-0022's suppression a SECOND, independent cause. The
            // bearing is a subtraction of the locator bearing and the phone's compass
            // heading, so an uncalibrated magnetometer breaks the other half of it —
            // a position ADR-0022 is perfectly happy with is still withheld when the
            // compass reports UNRELIABLE.
            vectorSuppressedReason = phone.compassTrust == .unreliable
                ? "compass unreliable — move away from metal, or figure-eight the phone"
                : nil
        } else {
            vector = nil
            vectorSuppressedReason = hasFix
                ? "reported position is beyond radio range"
                : "position moved further than the rocket could have travelled"
        }
    }
    func disconnect() { transport.disconnect() }

    private func ingest(_ frame: [UInt8]) {
        frameCount += 1
        let type = MsgType(rawValue: frame[1])
        if let type { countsByType[type, default: 0] += 1 }

        // Decode the two authenticated broadcasts. Note these arrive from EVERY
        // locator on the channel, not just one we are connected to — ADR-0020 —
        // so anything derived from them must eventually be gated on locator_id.
        // Nothing here is gated yet; this screen reports what arrived, whoever sent it.
        switch type {
        case .preLaunchData:
            if let m = PreLaunchData.parse(frame) {
                lastLocatorId = m.locatorId
                lastPrelaunchFrame = frame
                lastPrelaunchLocatorId = m.locatorId
                lastPrelaunchDeviceName = m.deviceName
                if admit(frame, m.locatorId, WireProtocol.prelaunchBaseStructSize,
                         deviceName: m.deviceName, receiverChannel: Int(m.channel)) {
                    prelaunch = m
                    latestBroadcast = .preLaunch
                    lastPreLaunchMessage = Date()
                    padAlert = m.padAlert
                    padAlertSnoozeMinutes = m.padAlertSnoozeMinutes
                    remoteLocatorConfig = LocatorConfig.from(m)
                    armed = m.armed                     // newest broadcast wins
                    flightState = .waitingLaunch        // ...and so does flight state
                    updateVector(lat: m.latitude, lon: m.longitude,
                                 satellites: m.satellites, gpsStatus: m.gpsStatus,
                                 state: .waitingLaunch, altitudeAglM: m.altitudeAgl)
                    updateLinkQuality(rssi: Int(m.rssi), snr: Int(m.snr),
                                      noiseFloor: Int(m.noiseFloor))
                    logPrelaunchFrame(m, at: Date())
                }
                // OUTSIDE the recognition gate, deliberately: the receiver's own
                // channel and name describe the user's receiver, not the locator that
                // happened to carry them. Gating them on recognising the locator would
                // leave Receiver Settings blank in exactly the case it is most needed —
                // an unrecognised locator on the channel you are trying to move off.
                remoteReceiverConfig.channel = Int(m.channel)
                if !m.receiverName.isEmpty { remoteReceiverConfig.deviceName = m.receiverName }
            }
        case .telemetryData:
            if let m = TelemetryData.parse(frame) {
                lastLocatorId = m.locatorId
                if admit(frame, m.locatorId, WireProtocol.telemetryBaseStructSize) {
                    telemetry = m
                    latestBroadcast = .telemetry
                    // TelemetryData carries no pad alert — it is an ON-PAD condition,
                    // and this message means armed or in flight. Cleared EXPLICITLY,
                    // because `PreLaunchData` stops arriving at exactly this point:
                    // reported from the phone as an escalation that would not go away
                    // when the locator was armed, and then vanished when it was
                    // disarmed — which is the stale value being replaced at last,
                    // the wrong way round.
                    padAlert = .quiet
                    padAlertSnoozeMinutes = 0
                    armed = m.armed                     // newest broadcast wins
                    flightState = m.flightState         // ...and so does flight state
                    updateVector(lat: m.latitude, lon: m.longitude,
                                 satellites: m.satellites, gpsStatus: m.gpsStatus,
                                 state: m.flightState, altitudeAglM: m.altitudeAgl,
                                 // NED: down is positive, so vertical velocity IS the
                                 // descent rate with no negation. Android passes
                                 // velNed.z here for the same reason.
                                 descentRateMs: m.velocityNed.z)
                    updateLinkQuality(rssi: Int(m.rssi), snr: Int(m.snr),
                                      noiseFloor: Int(m.noiseFloor))
                    logTelemetryFrame(m, at: Date())
                }
            }
        case .receiverInfo:
            // The ADR-0012 health probe's answer, and the ONLY message the receiver
            // sends with no locator involved.
            if let m = ReceiverInfo.parse(frame) {
                receiverInfo = m
                // The receiver emits one of these when it follows a locator change on its
                // own initiative; reaching that code proves the forward TRANSMITTED. Match
                // on the channel — a receipt carrying the OLD channel is the recovery
                // revert answering, and must not re-base the confirm window.
                noteChannelMoveReceipt(channel: Int(m.channel))
                remoteReceiverConfig.channel = Int(m.channel)
                if !m.deviceName.isEmpty { remoteReceiverConfig.deviceName = m.deviceName }
                pollChannel(noiseFloor: Int(m.noiseFloor), badFrames: m.badFrames)
                logReceiverInfoFrame(m, at: Date())
            }
        case .versionInfo:
            if let m = VersionInfo.parse(frame) {
                versionInfo = m
                versionInfoStale = false
            }
        case .channelSurvey:
            if let r = ChannelSurvey.parse(frame) {
                channelSurvey = r
                surveyInProgress = false
            }
        case .locatorSearchResult:
            if let r = LocatorSearchResult.parse(frame) { onLocatorSearchResult(r) }

        case .deploymentTest:
            // Adopted only while a test is believed live, exactly as Android gates it:
            // an unsolicited countdown belongs to a test this app did not start, and the
            // screen has nothing useful to say about one.
            //
            // The watchdog is re-armed **even while a cancel is pending**. A countdown
            // that crossed the cancel in flight must not be read as the cancel being
            // refused; the countdown STOPPING is what settles that.
            if deploymentTestActive, let m = DeploymentTestCountdown.parse(frame) {
                deploymentTestCountdown = m.secondsRemaining
                armDeploymentTestSilence()
            }

        // The flight-profile messages are NOT authenticated — they carry no locator id
        // and no auth tag, so there is nothing to gate them on. They arrive only in
        // answer to a request this app addressed to the connected locator, which is
        // what makes that acceptable and also what the ack path re-checks.
        case .flightMetadata:
            if flightData.onFlightMetadata(frame) {
                flightProfileMetadata = flightData.metadata
                flightProfileMetadataState = .ackUpdated
            }
        case .flightEvents:
            // Only adopt the summary for the record being viewed: the locator repeats
            // this frame, and a late one from a previous record would mislabel the
            // chart on screen.
            if let e = FlightEvents.parse(frame), e.record == flightProfileArchivePosition {
                flightEvents = e
            }
        case .flightData:
            if let ack = flightData.onFlightData(frame) {
                sendFlightDataAck(ack)
                publishFlightSamples()
                flightProfileDataState = flightData.progress.complete ? .ackUpdated : .sent
            } else {
                // The empty-record marker returns no ack, and it is the one case that
                // changes the screen without a packet being absorbed.
                flightTransferProgress = flightData.progress
            }
        case .flightDataParity:
            if let ack = flightData.onFlightDataParity(frame) {
                sendFlightDataAck(ack)
                publishFlightSamples()
                flightProfileDataState = flightData.progress.complete ? .ackUpdated : .sent
            }
        default:
            break
        }

        let stamp = String(format: "%7.1fs", Date().timeIntervalSince(started))
        let name = type.map(String.init(describing:)) ?? "unknown(\(frame[1]))"
        recent.insert("\(stamp)  \(name)  \(frame.count)B", at: 0)
        if recent.count > 40 { recent.removeLast() }
    }

    /// Run one broadcast past the gate. Returns true if its data may be displayed.
    ///
    /// Both broadcasts arrive from EVERY locator on the channel (ADR-0020), and at
    /// close range even from locators on other channels — off-channel capture is
    /// expected physics that no firmware change can fix, which is precisely why the
    /// identity gate rather than the radio has to keep the wrong rocket off screen.
    ///
    /// - Parameter receiverChannel: the channel carried by **this frame**, where the
    ///   message has one. `PreLaunchData` does; `TelemetryData` has no room for it and
    ///   passes nil, which falls back to the app's cached receiver config. Using the
    ///   frame's own value where it exists matters: the cache lags by one broadcast, and
    ///   is wrong exactly when a locator broadcasts once and goes quiet — which is the
    ///   case the search is for.
    private func admit(_ frame: [UInt8], _ locatorId: UInt32, _ baseSize: Int,
                       deviceName: String? = nil, receiverChannel: Int? = nil) -> Bool {
        // An authorized locator does NOT get the connection back just because we opened
        // the slot on the way somewhere else. A receiver-only move releases the connection
        // before the change goes out, and the locator we are leaving goes on broadcasting
        // into that empty slot at 1 Hz until the receiver actually retunes. Admitting one
        // of those frames re-adopts the old locator AND clears
        // `awaitingChannelRecognition`, so the challenge armed for the new channel never
        // fires — the reported "no password prompt from a search result, but the conflict
        // banner's Connect works". See `LocatorConnection.isFromChannelBeingLeft`.
        //
        // Asked BEFORE `gate.evaluate`, which is where iOS's shape differs from Android's:
        // `evaluate` authorizes and takes the connection in one mutating step, so the only
        // place to intervene between those two is here. The name and channel are still
        // recorded — they are true facts about a locator we are authorized for, and the
        // search runs on them — exactly as Android records them before its own guard.
        if gate.isAuthorized(frame: frame, locatorId: locatorId, baseSize: baseSize),
           LocatorConnection.isFromChannelBeingLeft(
               frameChannel: receiverChannel,
               previousChannel: channelChangePreviousChannel,
               awaitingRecognition: awaitingChannelRecognition,
               moveInFlight: receiverConfigMessageState != .idle) {
            noteName(locatorId, deviceName)
            noteChannel(locatorId, receiverChannel)
            return false
        }

        switch gate.evaluate(frame: frame, locatorId: locatorId, baseSize: baseSize) {
        case .accepted(let id):
            // The channel change resolved itself: something we are entitled to display
            // is on the new channel, so there is nothing left to revert.
            awaitingChannelRecognition = false
            noteName(id, deviceName)
            noteChannel(id, receiverChannel)
            connectedLocatorId = id
            lastLocatorMessage = Date()
            conflictingLocatorIds.remove(id)
            unauthorizedLocatorIds.remove(id)
            clearConflictIfStale(acceptedId: id)
            adoptStoredLabel(id)
            return true
        case .conflict(let id):
            // A different AUTHORIZED locator, heard while ours is still live. Warn, but
            // leave the connection where it is — switching is the user's call.
            noteName(id, deviceName)
            noteChannel(id, receiverChannel)
            conflictingLocatorIds.insert(id)
            lastForeignBroadcast = Date()
            noteConflict(id)
            return false
        case .unauthorized(let id):
            unauthorizedLocatorIds.insert(id)
            // Keep the challenge frame current while its dialog is open.
            if challenge?.locatorId == id { challengeFrame = frame }

            // A deliberate channel change landed on a locator we do not hold the
            // password for. **Challenge it, and do not raise the conflict banner** —
            // the user went here on purpose, so "somebody else is on your channel" is
            // not the right thing to say about the channel they just chose. Cancelling
            // reverts, which is the only way back: nothing else on this channel is
            // displayable, so a dismissed prompt would leave a blank screen.
            //
            // The trigger matters. `.passive` refuses to prompt while anything is
            // connected and stays silent for a locator declined before, both of which
            // are wrong here; `.channelChange` asks regardless.
            if awaitingChannelRecognition,
               policy.shouldChallenge(locatorId: id,
                                      hasDeviceName: deviceName != nil,
                                      connected: connectedLocatorId,
                                      challengeOpen: challenge != nil,
                                      trigger: .channelChange) {
                awaitingChannelRecognition = false
                challengeFrame = frame
                challenge = LocatorChallenge(locatorId: id, deviceName: deviceName ?? "",
                                             previousChannel: channelChangePreviousChannel)
                return false
            }

            // **The locator we believe we are connected to has stopped
            // authenticating** — its password was changed on the device. Reported from
            // the phone 2026-08-29 and reproduced: the app admitted nothing further,
            // could not prompt (the passive trigger refuses while anything is
            // connected), and showed the conflict banner calling this very locator
            // "another locator" over a panel reading "No Locator". There was no way out
            // short of dropping the BLE link.
            //
            // The connection is RELEASED first, because it is a stale belief rather
            // than a live connection to protect: the evidence it rested on is this
            // locator's own authenticated broadcasts, and those have stopped verifying.
            // Releasing it is also what lets the prompt through, and what stops the
            // banner describing the holder as somebody else.
            if id == connectedLocatorId {
                gate.disconnect()
                connectedLocatorId = nil
                if policy.shouldChallenge(locatorId: id,
                                          hasDeviceName: deviceName != nil,
                                          connected: nil,
                                          challengeOpen: challenge != nil,
                                          trigger: .credentialsChanged) {
                    challengeFrame = frame
                    challenge = LocatorChallenge(locatorId: id, deviceName: deviceName ?? "")
                }
                return false
            }

            // Never disturbs a standing connection: an armed stranger on the channel
            // must not knock out the locator we are connected to.
            noteConflict(id)
            if policy.shouldChallenge(locatorId: id,
                                      hasDeviceName: deviceName != nil,
                                      connected: connectedLocatorId,
                                      challengeOpen: challenge != nil,
                                      trigger: .passive) {
                challengeFrame = frame
                challenge = LocatorChallenge(locatorId: id, deviceName: deviceName ?? "")
            }
            return false
        }
    }

    /// Remember what an **authorized** locator calls itself, for the flight in which it
    /// stops saying so.
    ///
    /// Arming stops `PreLaunchData` and `TelemetryData` has no name field, so a name has
    /// to come from something remembered; `adoptStoredLabel` is the other half.
    ///
    /// Called on `.accepted` **and on `.conflict`** — Android does this before its
    /// `mayConnect` check (`RocketViewModel.noteLocatorName`, app `b209671`), so an
    /// authorized locator it declines to connect to is still named. That case is
    /// precisely the two-locator one: hear the second rocket's broadcast while the first
    /// holds the link, then switch to it after it is armed, and the name has to have
    /// been kept from the broadcast the app declined to act on. Not called on
    /// `.unauthorized` — a name is only worth keeping for a locator this app is entitled
    /// to display.
    ///
    /// `deviceName` is nil for `TelemetryData`, which carries no name; an empty or
    /// unchanged name is dropped inside `noteName`, so this is cheap at the 1 Hz
    /// broadcast rate.
    private func noteName(_ locatorId: UInt32, _ deviceName: String?) {
        guard let deviceName else { return }
        store.noteName(locatorId: locatorId, name: deviceName)
    }

    /// Remember where an **authorized** locator was just heard, for the search to start
    /// from (ADR-0029).
    ///
    /// Called from the same two branches as `noteName`, and for the same reason: Android
    /// writes both before its `mayConnect` check, so a second authorized locator heard
    /// while ours holds the link is still remembered — which is precisely the two-rocket
    /// case the candidate list exists to exploit.
    ///
    /// **Not called on `.unauthorized`.** That is somebody else's rocket, and seeding
    /// your search with their channel would spend a full broadcast period looking
    /// somewhere you have no reason to look.
    private func noteChannel(_ locatorId: UInt32, _ receiverChannel: Int?) {
        store.noteChannel(locatorId: locatorId,
                          channel: receiverChannel ?? remoteReceiverConfig.channel)
    }

    /// Name an accepted locator from what was stored when it was authorized.
    ///
    /// **An armed locator carries no name.** It broadcasts `TelemetryData`, which has no
    /// `device_name` field at all, so a locator first heard while armed — the app opened
    /// mid-flight, or with the rocket already on the pad — left the status panel with
    /// nothing to put in the locator row, and it read "No Locator" while the app was
    /// plainly receiving and plotting that locator's telemetry.
    ///
    /// Android does exactly this, in the same place (`evaluateRecognition`, on accept):
    /// falls back to the stored label, and lets the first `PreLaunchData` overwrite it
    /// with the live value as soon as the locator disarms. The difference here is WHICH
    /// locators have a name to fall back to: Android writes one only when a password is
    /// accepted, so an open locator — the default state — is never named while armed.
    /// This app stores the name of every locator it accepts a `PreLaunchData` from, so
    /// the fallback covers a locator that has simply been heard before.
    private func adoptStoredLabel(_ locatorId: UInt32) {
        guard remoteLocatorConfig.deviceName.isEmpty,
              let label = store.label(for: locatorId) else { return }
        remoteLocatorConfig.deviceName = label
    }

    /// Submit a typed password. Returns true if it authenticated.
    ///
    /// A wrong password leaves the dialog open to retry, per ADR-0006 — retyping is
    /// far more likely than the user having the wrong locator.
    @discardableResult
    func submitPassword(_ password: String) -> Bool {
        guard let c = challenge, let frame = challengeFrame,
              let key = KnownLocatorStore.verify(password: password, frame: frame,
                                                 baseSize: WireProtocol.prelaunchBaseStructSize)
        else {
            challenge?.rejected = true
            return false
        }
        // The name is stored WITH the key, as Android's `rememberLocator` does: it is
        // the only chance to learn it, since the dialog is raised on `PreLaunchData`
        // and an armed locator never sends one again until it disarms.
        store.remember(locatorId: c.locatorId, passwordKey: key, label: c.deviceName)
        gate.remember(locatorId: c.locatorId, passwordKey: key)
        policy.reconsider(c.locatorId)
        unauthorizedLocatorIds.remove(c.locatorId)
        // **Take the connection now**, as Android's `submitPassword` does, rather than
        // leaving it to the next broadcast. Waiting works only when the slot is free:
        // with a previous holder still inside `connectionHold` the very next frame comes
        // back as `conflict`, so a correct password bought fifteen seconds of a blank
        // screen. The frame that raised this dialog is one this locator authenticated,
        // which is the same evidence the arriving-packet path would have used.
        gate.connect(to: c.locatorId)
        connectedLocatorId = c.locatorId
        conflictLocatorId = nil
        conflictingLocatorIds.remove(c.locatorId)
        awaitingChannelRecognition = false
        challenge = nil
        challengeFrame = nil
        return true
    }

    /// Dismiss without connecting.
    ///
    /// **A channel-change challenge reverts the receiver**; a passive one is remembered
    /// as declined. The two are different situations: a passive prompt is about a
    /// stranger on the channel we were already using, and dismissing it leaves everything
    /// as it was — but a channel-change prompt is the only thing standing between the
    /// user and a screen with nothing on it, because the locator they left is off-channel
    /// and the one they found is not displayable. Cancel has to mean "put it back".
    ///
    /// Not remembered as declined in that case, deliberately: the user declined a
    /// *channel*, not a locator, and re-declining is free the next time they go there.
    func declineChallenge() {
        guard let c = challenge else { return }
        if let previous = c.previousChannel {
            awaitingChannelRecognition = false
            var target = remoteReceiverConfig
            target.channel = previous
            changeReceiverConfig(target)
        } else {
            policy.decline(c.locatorId)
        }
        challenge = nil
        challengeFrame = nil
    }

    /// The explicit user switch — ADR-0006's conflict-banner Connect action. The only
    /// thing besides holder silence that moves a live connection.
    func switchTo(_ locatorId: UInt32) {
        plausibility.reset()      // a new rocket is not judged against the old one's track
        vector = nil
        track.removeAll()
        policy.reconsider(locatorId)
        gate.connect(to: locatorId)
        connectedLocatorId = locatorId
        conflictingLocatorIds.remove(locatorId)
        prelaunch = nil
        telemetry = nil
        // Held separately from the frames above, so it has to be cleared with them —
        // otherwise the newly connected locator wears the previous one's flight state
        // until its first broadcast lands.
        flightState = .waitingLaunch
    }

    var stateLabel: String {
        switch state {
        case .idle:           return "Idle"
        case .unsupported:    return "Bluetooth unsupported"
        case .unauthorized:   return "Bluetooth permission denied"
        case .poweredOff:     return "Bluetooth off"
        case .scanning:       return "Scanning for FFE0…"
        case .noDevicesFound: return "No receiver found"
        case .connecting:     return "Connecting…"
        case .connected:      return "Connected — resolving GATT…"
        case .ready:          return "Ready"
        case .disconnected:   return "Disconnected"
        }
    }
}

/// The runner's side effects, bound to a live `LinkViewModel`.
///
/// A separate type rather than a conformance on the view model itself, so the runner's
/// surface stays exactly the eight operations it needs and nothing on the view model
/// accidentally satisfies it. Holds the model weakly-by-reference in the ordinary way —
/// the runner never outlives the resolve call that owns it.
@MainActor
private struct ChannelMoveLiveOps: ChannelMoveRunner.Ops {
    let model: LinkViewModel
    /// The config the move staged, re-sent verbatim by the one permitted retry.
    let target: LocatorConfig

    func probeInProgress() async -> Bool { model.probeIsRunning() }

    func runProbe(newChannel: Int, oldChannel: Int) async -> ChannelMoveRunner.ProbeRun? {
        await model.runChannelProbe(newChannel: newChannel, oldChannel: oldChannel)
    }

    func pause(_ interval: TimeInterval) async {
        try? await Task.sleep(for: .seconds(interval))
    }

    func now() async -> Date { Date() }

    func pointReceiverAt(_ channel: Int) async { model.pointReceiverAtForMove(channel) }

    func awaitRelink(oldChannel: Int, since: Date) async -> Bool {
        await model.awaitRelinkForMove(oldChannel: oldChannel, since: since)
    }

    func resendLocatorConfig() async -> Bool { model.resendLocatorConfigForMove(target) }

    func awaitConfirmation() async -> Bool { await model.awaitMoveConfirmation(target) }

    func onVerdict(_ verdict: ChannelMove.Verdict) async {
        model.noteChannelMoveVerdict(verdict)
    }
}
