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

    private func updateLinkQuality(rssi: Int, snr: Int, noiseFloor: Int, now: Date = Date()) {
        quietestFloor = LinkQuality.updateQuietestFloor(current: quietestFloor, sample: noiseFloor)

        // A gap longer than one broadcast period means at least one was lost.
        if let last = lastAcceptedBroadcast,
           now.timeIntervalSince(last) >= LinkQuality.lossyGap {
            lastLossy = now
        }
        lastAcceptedBroadcast = now

        let lossy = lastLossy.map { now.timeIntervalSince($0) < LinkQuality.lossMemory } ?? false
        let foreign = lastForeignBroadcast.map {
            now.timeIntervalSince($0) < LinkQuality.lossMemory
        } ?? false

        linkVerdict = LinkQuality.classify(
            rssi: rssi, snr: snr,
            noiseFloor: noiseFloor, quietestFloor: quietestFloor,
            lossy: lossy, foreignLocator: foreign)
    }

    /// Recorded ground track of the connected locator, oldest first.
    ///
    /// Deduped and capped: at 1 Hz an unbounded array would grow all afternoon, and
    /// consecutive fixes from a rocket sitting on the pad differ only by GPS noise,
    /// which would draw a scribble rather than a track.
    @Published private(set) var track: [CLLocationCoordinate2D] = []
    private static let trackMinSeparationM = 2.0
    private static let trackMaxPoints = 2_000

    private func recordTrack(lat: Double, lon: Double, hasFix: Bool) {
        // Only fixed positions join the track. A fixless reading may be good enough to
        // keep quoting a stale distance (ADR-0022) but not to draw as ground truth.
        guard hasFix, lat != 0 || lon != 0 else { return }
        let point = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        if let last = track.last {
            let step = LocatorVector.between(from: (last.latitude, last.longitude),
                                             to: (lat, lon)).distanceM
            guard Double(step) >= Self.trackMinSeparationM else { return }
        }
        track.append(point)
        if track.count > Self.trackMaxPoints { track.removeFirst(track.count - Self.trackMaxPoints) }
    }

    /// The connected locator's latest position, if it reported one.
    var rocketCoordinate: CLLocationCoordinate2D? {
        if let t = telemetry, t.latitude != 0 || t.longitude != 0 {
            return CLLocationCoordinate2D(latitude: t.latitude, longitude: t.longitude)
        }
        if let p = prelaunch, p.latitude != 0 || p.longitude != 0 {
            return CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
        }
        return nil
    }

    /// Android's `isInFlight`: armed, OR a flight state other than WaitingLaunch.
    ///
    /// The second half matters after landing — the locator disarms and returns to
    /// PreLaunchData, but the flight state stays `Landed`, so speed and attitude keep
    /// showing. That is exactly when someone is walking out to the rocket.
    var isInFlight: Bool {
        let armed = telemetry?.armed ?? prelaunch?.armed ?? false
        let state = telemetry?.flightState ?? .waitingLaunch
        return armed || state != .waitingLaunch
    }

    /// Whether the locator is currently armed, from whichever broadcast is newest.
    var armed: Bool { telemetry?.armed ?? prelaunch?.armed ?? false }

    // MARK: - Commands (ADR-0020: gated on CONNECTED, not merely authorized)

    /// True when an arm/disarm may be sent: a locator is connected and addressable.
    var canSendArmCommand: Bool {
        guard let id = connectedLocatorId else { return false }
        return gate.mayCommand(id) && state == .ready
    }

    /// Toggle the locator's armed state. Addressed to the connected locator, because
    /// an unaddressed Arm reaches every locator on the channel.
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

    /// Drop the link and look for the receiver again.
    func rescan() {
        transport.disconnect()
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

    /// ADR-0017 trust state for the drawn position.
    var markerState: RocketMarkerState {
        RocketMarkerState.from(
            lastMessageAge: lastLocatorMessage.map { Date().timeIntervalSince($0) } ?? .infinity,
            gpsStatus: telemetry?.gpsStatus ?? prelaunch?.gpsStatus)
    }

    var rocketAccuracyM: Double? {
        if let t = telemetry { return Double(t.horizontalAccuracy) }
        if let p = prelaunch { return Double(p.horizontalAccuracy) }
        return nil
    }

    private let transport = BluetoothTransport()
    private let started = Date()

    init() {
        for (id, key) in store.keysById { gate.remember(locatorId: id, passwordKey: key) }
        transport.onDiscover = { [weak self] peripherals in
            Task { @MainActor in
                guard let self else { return }
                self.discoveredReceivers = peripherals.map {
                    ($0.identifier, $0.name ?? "Unnamed receiver")
                }
                // Reconnecting to the receiver used last is not a choice worth
                // interrupting for; only ask when it is genuinely ambiguous.
                if let known = self.transport.lastKnownPeripheral,
                   let match = peripherals.first(where: { $0.identifier == known }) {
                    self.transport.connect(to: match)
                }
            }
        }
        transport.onStateChange = { [weak self] s in
            Task { @MainActor in self?.state = s }
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
    }

    /// Recompute the vector to the connected locator after a new broadcast.
    ///
    /// ADR-0022: the range ceiling applies to every quoted distance whatever the
    /// locator claims about its own fix, and a fixless reading is judged on having
    /// jumped rather than on being fixless.
    private func updateVector(lat: Double, lon: Double, satellites: UInt8,
                              gpsStatus: SensorHealth, state: FlightStates,
                              altitudeAglM: Float) {
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
        recordTrack(lat: lat, lon: lon, hasFix: hasFix)

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
                if admit(frame, m.locatorId, WireProtocol.prelaunchBaseStructSize,
                         deviceName: m.deviceName) {
                    prelaunch = m
                    updateVector(lat: m.latitude, lon: m.longitude,
                                 satellites: m.satellites, gpsStatus: m.gpsStatus,
                                 state: .waitingLaunch, altitudeAglM: m.altitudeAgl)
                    updateLinkQuality(rssi: Int(m.rssi), snr: Int(m.snr),
                                      noiseFloor: Int(m.noiseFloor))
                }
            }
        case .telemetryData:
            if let m = TelemetryData.parse(frame) {
                lastLocatorId = m.locatorId
                if admit(frame, m.locatorId, WireProtocol.telemetryBaseStructSize) {
                    telemetry = m
                    updateVector(lat: m.latitude, lon: m.longitude,
                                 satellites: m.satellites, gpsStatus: m.gpsStatus,
                                 state: m.flightState, altitudeAglM: m.altitudeAgl)
                    updateLinkQuality(rssi: Int(m.rssi), snr: Int(m.snr),
                                      noiseFloor: Int(m.noiseFloor))
                }
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
            return true
        case .conflict(let id):
            conflictingLocatorIds.insert(id)
            lastForeignBroadcast = Date()
            return false
        case .unauthorized(let id):
            unauthorizedLocatorIds.insert(id)
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
        store.remember(locatorId: c.locatorId, passwordKey: key)
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
