import Foundation
import Combine
import CoreLocation

/// Drives the link screen. Deliberately thin: it owns the transport, counts what
/// arrives, and answers health probes. No telemetry parsing yet — the point of this
/// screen is to find out whether the transport works against real hardware.
@MainActor
final class LinkViewModel: ObservableObject {

    @Published private(set) var state: TransportState = .idle
    @Published private(set) var frameCount = 0
    @Published private(set) var badFrames = 0
    @Published private(set) var countsByType: [MsgType: Int] = [:]
    @Published private(set) var recent: [String] = []
    @Published private(set) var rejects: [String] = []
    @Published private(set) var probesSent = 0

    /// Latest decoded broadcast from the locator, whichever kind arrived.
    @Published private(set) var prelaunch: PreLaunchData?
    @Published private(set) var telemetry: TelemetryData?
    @Published private(set) var lastLocatorId: UInt32?
    /// When the connected locator last spoke. Drives the marker's trust colour.
    @Published private(set) var lastLocatorMessage: Date?
    /// The locator whose data is on screen. Nothing else reaches the display.
    @Published private(set) var connectedLocatorId: UInt32?
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
    private var store = KnownLocatorStore()
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
    @Published private(set) var remoteReceiverConfig = ReceiverConfig()
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

    func clearPendingChannelMove() { pendingChannelMove = nil }

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
        transport.send(msg)
        locatorConfigMessageState = .sent

        Task { @MainActor in
            if await waitForLocatorConfig(target) {
                locatorConfigMessageState = .ackUpdated
            } else if locatorConfigMessageState == .sendFailure {
                // Nothing left the phone, so the receiver never switched and there is
                // nothing to recover. Leave the failure standing.
            } else if channel != oldChannel {
                locatorConfigMessageState =
                    await recoverLocatorChannel(target: target, oldChannel: oldChannel)
                    ? .ackUpdated : .notAcknowledged
            } else if locatorConfigMessageState.isInFlight {
                locatorConfigMessageState = .notAcknowledged
            }
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
    private func waitForLocatorConfig(_ target: LocatorConfig) async -> Bool {
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if remoteLocatorConfig == target { return true }
            if locatorConfigMessageState == .sendFailure { return false }
        }
        return false
    }

    /// ADR-0011 invariant 4, and the reason a failed move is not simply reported.
    ///
    /// If the locator never appears on the new channel it most likely missed the LoRa
    /// command and is still on the old one — while the receiver, which forwarded that
    /// command, has already followed onto the new channel. **The link is split, and the
    /// user cannot fix it from here**: the locator is out of reach by definition.
    ///
    /// So pull the RECEIVER back over BLE, which is always reachable, wait for
    /// broadcasts to resume on the old channel, and retry the locator change once.
    private func recoverLocatorChannel(target: LocatorConfig, oldChannel: Int) async -> Bool {
        guard let id = connectedLocatorId,
              let back = OutboundMessage.receiverDirected(
                .receiverCfgChgRequest,
                payload: ReceiverConfig(channel: oldChannel,
                                        deviceName: remoteReceiverConfig.deviceName).payload)
        else { return false }
        transport.send(back)

        var relinked = false
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if remoteReceiverConfig.channel == oldChannel,
               remoteLocatorConfig.loraChannel == oldChannel {
                relinked = true
                break
            }
        }
        guard relinked else { return false }

        guard let retry = OutboundMessage.locatorDirected(.locatorCfgChgRequest,
                                                          targetLocatorId: id,
                                                          payload: target.payload)
        else { return false }
        transport.send(retry)
        locatorConfigMessageState = .sent
        return await waitForLocatorConfig(target)
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
        transport.send(msg)
        receiverConfigMessageState = .sent

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

    /// Android's `LINK_LIVENESS_TICK_MS` and `CHANNEL_WATCH_TICK_MS` / `_SILENCE_MS`.
    private static let livenessTick: TimeInterval = 0.5
    private static let channelWatchTick: TimeInterval = 2
    private static let channelWatchSilence: TimeInterval = 5

    private var livenessTimer: Timer?
    private var channelWatchTimer: Timer?

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
    /// The second half matters after landing — the locator disarms and returns to
    /// PreLaunchData, but the flight state stays `Landed`, so speed and attitude keep
    /// showing. That is exactly when someone is walking out to the rocket.
    var isInFlight: Bool { armed || (telemetry?.flightState ?? .waitingLaunch) != .waitingLaunch }

    /// Armed state from the NEWEST broadcast.
    ///
    /// Not "telemetry if present": telemetry is deliberately retained across a disarm
    /// so speed and attitude survive landing, which made that reading report armed
    /// forever once a locator had ever been armed — and with it, in-flight forever.
    /// A disarmed locator sends PreLaunchData, so the newest packet is the answer.
    @Published private(set) var armed = false

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
        let state = telemetry?.flightState ?? .waitingLaunch
        if armed, state != .waitingLaunch, state != .landed {
            transientMessage = "Can't disarm while the rocket is in flight. Wait until it has landed."
            return
        }

        let type: MsgType = armed ? .disarmRequest : .armRequest
        guard let msg = OutboundMessage.locatorDirected(type, targetLocatorId: id) else { return }
        transport.send(msg)
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
        transport.send(msg)
        return true
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
        transport.send(msg)
        flightProfileDataState = .sent
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
        // this link, and re-showing them on reconnect beats a blank field.
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
        connectedLocatorId = nil
        conflictingLocatorIds.removeAll()
        unauthorizedLocatorIds.removeAll()
        linkVerdict = .normal
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

    private let transport = BluetoothTransport()
    private let started = Date()

    init() {
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
                         deviceName: m.deviceName) {
                    prelaunch = m
                    latestBroadcast = .preLaunch
                    lastPreLaunchMessage = Date()
                    padAlert = m.padAlert
                    padAlertSnoozeMinutes = m.padAlertSnoozeMinutes
                    remoteLocatorConfig = LocatorConfig.from(m)
                    // Remembered for the next launch, and for the rest of THIS one:
                    // arming the locator stops these broadcasts, and `TelemetryData`
                    // carries no name. Kept for open locators too, which is where this
                    // goes past Android — see `KnownLocatorStore` and UI_PARITY.md.
                    store.noteName(locatorId: m.locatorId, name: m.deviceName)
                    armed = m.armed                     // newest broadcast wins
                    updateVector(lat: m.latitude, lon: m.longitude,
                                 satellites: m.satellites, gpsStatus: m.gpsStatus,
                                 state: .waitingLaunch, altitudeAglM: m.altitudeAgl)
                    updateLinkQuality(rssi: Int(m.rssi), snr: Int(m.snr),
                                      noiseFloor: Int(m.noiseFloor))
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
                    updateVector(lat: m.latitude, lon: m.longitude,
                                 satellites: m.satellites, gpsStatus: m.gpsStatus,
                                 state: m.flightState, altitudeAglM: m.altitudeAgl,
                                 // NED: down is positive, so vertical velocity IS the
                                 // descent rate with no negation. Android passes
                                 // velNed.z here for the same reason.
                                 descentRateMs: m.velocityNed.z)
                    updateLinkQuality(rssi: Int(m.rssi), snr: Int(m.snr),
                                      noiseFloor: Int(m.noiseFloor))
                }
            }
        case .receiverInfo:
            // The ADR-0012 health probe's answer, and the ONLY message the receiver
            // sends with no locator involved.
            if let m = ReceiverInfo.parse(frame) {
                receiverInfo = m
                remoteReceiverConfig.channel = Int(m.channel)
                if !m.deviceName.isEmpty { remoteReceiverConfig.deviceName = m.deviceName }
                pollChannel(noiseFloor: Int(m.noiseFloor), badFrames: m.badFrames)
            }
        case .versionInfo:
            if let m = VersionInfo.parse(frame) { versionInfo = m }
        case .channelSurvey:
            if let r = ChannelSurvey.parse(frame) {
                channelSurvey = r
                surveyInProgress = false
            }

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
    private func admit(_ frame: [UInt8], _ locatorId: UInt32, _ baseSize: Int,
                       deviceName: String? = nil) -> Bool {
        switch gate.evaluate(frame: frame, locatorId: locatorId, baseSize: baseSize) {
        case .accepted(let id):
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
            conflictingLocatorIds.insert(id)
            lastForeignBroadcast = Date()
            noteConflict(id)
            return false
        case .unauthorized(let id):
            unauthorizedLocatorIds.insert(id)
            // Never disturbs a standing connection: an armed stranger on the channel
            // must not knock out the locator we are connected to.
            noteConflict(id)
            // Keep the challenge frame current while its dialog is open.
            if challenge?.locatorId == id { challengeFrame = frame }
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
        challenge = nil
        challengeFrame = nil
        return true
    }

    /// Dismiss without connecting. Remembered so it is not re-asked every broadcast.
    func declineChallenge() {
        if let c = challenge { policy.decline(c.locatorId) }
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
