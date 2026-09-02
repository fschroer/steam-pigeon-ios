import SwiftUI
import CoreLocation

/// The live map tab.
///
/// Layout mirrors Android's flight screen: the status column pinned top-left, the
/// draggable telemetry panel over the map, and the map filling everything.
struct MapScreen: View {
    @ObservedObject var model: LinkViewModel
    @ObservedObject var settings: AppSettings

    init(model: LinkViewModel, settings: AppSettings, sheet: Binding<MapSheet?>) {
        self.model = model
        self.settings = settings
        _sheet = sheet
        _voice = StateObject(wrappedValue: SpeechCoordinator(settings: settings))
    }

    @State private var recentre = 0
    /// Live camera, so the rose counter-rotates and the scale bar sizes itself.
    @State private var cameraBearing: Double = 0
    @State private var cameraZoom: Double = 15
    @State private var cameraCentre = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    /// Hoisted so a tap on the MAP closes the action panel.
    @State private var actionsExpanded = false
    @State private var tiltMode: MapTiltMode = .flat
    // All three default ON, as Android's `autoTargetMode`, `autoZoomMode` and
    // `compassEnabled` do (FlightMapScreen.kt, MapWithOverlays). They were false
    // here, which left the map inert on arrival and made the controls look broken:
    // the modes the app is *for* were the ones switched off.
    @State private var autoCentre = true
    @State private var autoZoom = true
    @State private var headingUp = true
    /// What this screen wants shown. **Owned by `RootView`, which presents it** — see
    /// the note on `RootSheet`. This screen names its sheet; it does not present one,
    /// because an ancestor that also presents (the password challenge) cannot while a
    /// descendant is presenting, and the prompt lost that race.
    @Binding var sheet: MapSheet?

    /// The voice and the haptic. Owned here because the map screen is where the pad
    /// alert is displayed, and the three channels should start and stop together.
    @StateObject private var voice: SpeechCoordinator

    var body: some View {
        // Measured HERE, at the top, rather than from the map's background. The panel
        // drag is clamped against this size, and the first attempt measured a
        // subview whose size arrived too late — so the clamp saw a zero container,
        // took its "not measured yet" path, and let the panel leave the screen.
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                FlightMapView(
                    rocket: model.rocketCoordinate,
                    phone: model.phone.coordinate,
                    rocketAccuracyM: model.rocketAccuracyM,
                    phoneAccuracyM: model.phone.horizontalAccuracyM,
                    // The archived record substitutes for the live track when engaged —
                    // see `LinkViewModel.mapTrack`.
                    track: model.mapTrack,
                    recentreToken: recentre,
                    markerState: model.markerState,
                    // NOT gated on compass trust. ADR-0023 Decision 5 suppresses the
                    // AR overlay at UNRELIABLE, and ADR-0022's mechanism withholds the
                    // quoted bearing — both of which iOS still does, in `updateVector`.
                    // The MAP is neither: it is an orientation aid, the rose carries
                    // the calibration mark that says the heading is doubted, and
                    // Decision 6 describes the map visibly correcting itself DURING the
                    // figure-eight — which it cannot do if interference froze it.
                    // Android agrees: its camera bearing is `hasCompass && compassEnabled`,
                    // with accuracy nowhere in it.
                    headingUpDeg: headingUp ? model.phone.trueHeadingDeg : nil,
                    pitchDeg: tiltMode.pitch(
                        // Newest-wins, not telemetry-only: Android ramps the tilt from
                        // `rocketState.altitudeAboveGroundLevel`, which both broadcasts
                        // write. Reading telemetry alone would hold the camera leaned
                        // at the last in-flight altitude after a disarm.
                        altitudeAglM: Double(model.altitudeAglM),
                        devicePitchDeg: model.phone.devicePitchDeg ?? 0),
                    autoCentreOn: autoCentre ? model.rocketCoordinate : nil,
                    autoZoom: autoZoom,
                    maxZoom: settings.mapMaxZoom,
                    // Changing any camera control is an explicit command and cancels
                    // the gesture backoff, so the tap takes effect now rather than up
                    // to five seconds later. Android does this with
                    // `LaunchedEffect(tiltMode, autoTargetMode, autoZoomMode,
                    // compassEnabled) { lastUserGestureTime = 0 }`.
                    controlsToken: controlsToken,
                    onCameraChange: { bearing, zoom, centre in
                        // MapLibre reports this from inside its own update, which can
                        // land mid-layout. Deferring keeps it an ordinary state change.
                        DispatchQueue.main.async {
                            cameraBearing = bearing
                            cameraZoom = zoom
                            cameraCentre = centre
                        }
                    }
                )
                // A tap anywhere on the map dismisses the action panel. Without this
                // the only way out is hitting the same small panel again, which is a
                // trap on a screen where every other gesture belongs to the map.
                .onTapGesture { actionsExpanded = false }

                HStack(alignment: .top, spacing: 8) {
                    Button { sheet = .menu } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 24))
                            .foregroundStyle(SPColor.onPrimaryContainer)
                            .frame(width: 48, height: 48)
                            .background(SPColor.primaryContainer,
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityLabel("Menu")

                    Spacer(minLength: 0)
                    statusPanel
                    Spacer(minLength: 0)

                    MapControlsColumn(
                        tiltMode: $tiltMode,
                        autoCentre: $autoCentre,
                        autoZoom: $autoZoom,
                        headingUp: $headingUp,
                        recording: $model.isRecordingTrack,
                        onResetTrack: { model.resetTrack() },
                        hasArchivedPath: !model.archivedTrack.isEmpty,
                        showArchivedPath: Binding(get: { model.showArchivedPath },
                                                  set: { _ in model.toggleArchivedPath() }))
                }
                .padding(8)

                if model.connectedLocatorId != nil {
                    statsPanel(in: proxy.size)
                }

                // Centre of the map, over everything: what is wrong with the rocket in
                // front of you. Gated on hearing from the locator at all — a banner
                // describing a rocket the app is no longer in contact with is a claim
                // it cannot make.
                if model.isLocatorFresh, let banner = FlightBanner.text(
                    padAlert: model.padAlert,
                    snoozeMinutes: model.padAlertSnoozeMinutes,
                    armed: model.armed,
                    locatorGpsLock: model.rocketCoordinate != nil) {
                    PulsingText(text: banner,
                                color: FlightBanner.color(padAlert: model.padAlert),
                                pulse: FlightBanner.pulses(padAlert: model.padAlert))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if !model.discoveredReceivers.isEmpty {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack { Spacer(); receiverPicker; Spacer() }
                        .frame(maxWidth: .infinity)
                }

                // Android uses a Toast; this is the same job — say why nothing
                // happened, then get out of the way.
                if let message = model.transientMessage {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(SPFont.bodyMedium)
                            .padding(12)
                            .background(SPColor.surfaceContainerHighest,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .padding(.bottom, 90)
                            .onAppear {
                                Task {
                                    try? await Task.sleep(for: .seconds(4))
                                    model.transientMessage = nil
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                }

                // The app's own compass rose, carrying the ADR-0023 calibration mark,
                // and the scale bar — both bottom-left, clear of the stats panel.
                VStack(alignment: .leading, spacing: 6) {
                    Spacer()
                    CompassRose(bearingDeg: cameraBearing, trust: model.phone.compassTrust)
                    MapScaleBar(zoom: cameraZoom, latitude: cameraCentre.latitude)
                }
                .padding(.leading, 10)
                .padding(.bottom, 16)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        // The locator's verdict drives the voice and the haptic. Gated on hearing from
        // it, exactly as the banner is: a warning about a rocket the app is out of
        // contact with is a claim it cannot make, and a haptic that outlives its cause
        // teaches the operator the phone is broken.
        .onChange(of: model.isLocatorFresh ? model.padAlert : .quiet) {
            voice.padAlert.update($0)
        }
        // Android speaks the arm state on every change, from the status panel.
        .onChange(of: model.armed) { voice.speech.say($0 ? "Armed" : "Disarmed") }
        // Every line that actually reaches the synthesizer is recorded in the App Flight
        // Log (ADR-0030). Set here rather than in `SpeechCoordinator` because this is the
        // first place both objects are in scope; `say` is the single funnel, so one hook
        // covers every callout the app has or gains.
        .onAppear { voice.speech.onSpoken = { [weak model] in model?.logAnnouncement($0) } }
        .onDisappear { voice.padAlert.stop() }
    }

    /// Changes whenever a camera control does, and is otherwise stable.
    ///
    /// Derived rather than kept as its own `@State` so it cannot drift out of step
    /// with the controls it stands for. Only inequality is ever tested, so a hash
    /// that differs run to run is fine.
    private var controlsToken: Int {
        var hasher = Hasher()
        hasher.combine(tiltMode)
        hasher.combine(autoCentre)
        hasher.combine(autoZoom)
        hasher.combine(headingUp)
        return hasher.finalize()
    }

    // MARK: - Overlays

    /// Bottom-right by default, dragged from there, clamped to the container.
    /// Re-centre also sends the telemetry panel home. The two belong together: both
    /// mean "put things back where I can see them", and it guarantees the panel is
    /// always recoverable even if its drag bounds misbehave.
    private func statsPanel(in container: CGSize) -> some View {
        let p = model.prelaunch
        let t = model.telemetry
        return VStack {
            Spacer()
            HStack {
                Spacer()
                LocatorStatsPanel(
                    // Same source as the status panel's locator row, and for the same
                    // reason — Android passes `locatorConfig` to `LocatorStats` too.
                    deviceName: model.remoteLocatorConfig.deviceName,
                    // The model's, not the retained frame's: `t` is the last
                    // telemetry ever received, which reads `Landed` forever once the
                    // locator has flown. See `LinkViewModel.flightState`.
                    flightState: model.flightState,
                    armed: model.armed,
                    inFlight: model.isInFlight,
                    distanceM: model.vector?.distanceM,
                    altitudeAglM: model.altitudeAglM,
                    // NED: down is positive, so a climb is the negation.
                    // Android shows total speed from the NED vector, not just the
                    // vertical component.
                    velocityMs: t.map { $0.velocityNed.magnitude },
                    inclinationDeg: t?.attitude.inclinationDeg,
                    headingDeg: t?.attitude.headingDeg,
                    accel: p?.accel,
                    gyro: p?.gyro,
                    latitude: model.rocketCoordinate?.latitude ?? 0,
                    longitude: model.rocketCoordinate?.longitude ?? 0,
                    // Android colours the distance row on the locator's GPS health.
                    gpsStatus: model.gpsStatus,
                    // `vector` is nil exactly when ADR-0022/0023 declined to stand
                    // behind the position, which is Android's `locatorDistancePlausible`
                    // — and the same judgement that put "Unknown" in the row above.
                    positionTrusted: model.vector != nil,
                    deployChannelText: p.map { cfg in
                        cfg.deployChannelModes.enumerated().map { i, mode in
                            DeployChannelText.line(channel: i + 1, mode: mode, config: cfg)
                        }
                    } ?? [],
                    // Newest broadcast wins — see `LinkViewModel.newest`. Reading
                    // telemetry-then-prelaunch here is what left a stale in-flight
                    // reading on screen after every disarm.
                    deployChannelContinuity: model.deployChannelContinuity,
                    onTapSpeak: nil,
                    containerSize: container,
                    homeToken: recentre
                )
            }
        }
        .padding(8)
    }


    /// The status rows plus the action dropdown, centred in the top row.
    private var statusPanel: some View {
        MapStatusPanel(
                    // The receiver's BLE name first, its configured name second — the
                    // order Android resolves this in. `prelaunch?.receiverName` alone
                    // left the row reading "Connected" whenever the locator was armed,
                    // since that field rides in a broadcast an armed locator stops
                    // sending.
                    receiverName: model.receiverDisplayName,
                    connectionState: model.state,
                    // Pre-launch-only fields, aged on their own clock: the locator stops
                    // sending them the moment it is armed, and nothing is worse than a
                    // battery reading that is quietly the one from before the flight.
                    receiverBatteryMv: model.isPreLaunchFresh ? model.prelaunch?.receiverBatteryMv : nil,
                    // NOT `prelaunch?.deviceName`: the locator stops sending
                    // `PreLaunchData` the moment it is armed, so that field is empty for
                    // the whole flight when the app was opened with the locator already
                    // armed. `remoteLocatorConfig` is the name the app currently believes
                    // — live from the last broadcast, or the stored label — exactly as
                    // Android reads `locatorConfig.deviceName` here.
                    locatorName: model.remoteLocatorConfig.deviceName,
                    locatorFresh: model.isLocatorFresh,
                    // Search first: it is the longer of the two and the one whose
                    // silence a user is most likely to misread.
                    scanInProgress: model.locatorSearch?.running == true ? "Searching…"
                                  : model.surveyInProgress ? "Scanning…" : nil,
                    satellites: model.satellites,
                    armed: model.armed,
                    locatorBatteryMv: model.isPreLaunchFresh ? model.prelaunch?.locatorBatteryMv : nil,
                    rssi: rssi,
                    snr: snr,
                    linkNote: linkNote,
                    canArm: model.canSendArmCommand,
                    armPending: model.armCommandPending,
                    onRescan: { model.rescan() },
                    onToggleArmed: { model.toggleArmed() },
                    locatorConnected: model.connectedLocatorId != nil,
                    linkReady: model.state == .ready,
                    onFindLocator: { sheet = .destination(.communication) },
                    padAlert: model.padAlert,
                    padAlertSnoozeMinutes: model.padAlertSnoozeMinutes,
                    onSnoozePadAlert: { model.snoozePadAlert() },
                    actionsExpanded: $actionsExpanded
                )
    }

    /// Offered when discovery finds receivers.
    @ViewBuilder private var receiverPicker: some View {
        if !model.discoveredReceivers.isEmpty {
            VStack(spacing: 0) {
                Text("Select receiver").font(SPFont.titleMedium).padding(.top, 12)
                Text("\(model.discoveredReceivers.count) device(s) found. Tap to connect.")
                    .font(SPFont.bodySmall)
                    .foregroundStyle(SPColor.onSurfaceVariant)
                    .padding(.bottom, 8)
                ForEach(model.discoveredReceivers, id: \.id) { r in
                    Divider()
                    Button { model.selectReceiver(r.id) } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text(r.name).font(SPFont.bodyLarge)
                            Spacer()
                        }
                        .padding(.vertical, 12).padding(.horizontal, 16)
                    }
                    .foregroundStyle(SPColor.onBackground)
                }
                Divider()
                Button("Cancel") { model.dismissReceiverPicker() }
                    .font(SPFont.labelLarge)
                    .padding(12)
            }
            .frame(maxWidth: 320)
            .background(SPColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20)
        }
    }

    /// ADR-0019 verdict as prose. `Congested` is the quieter of the two: the channel
    /// is occupied but our packets are still arriving clean.
    private var linkNote: (text: String, color: Color)? {
        switch model.linkVerdict {
        // Android's exact wording. "Channel busy" alone loses the reassurance that
        // matters most when it appears mid-flight: the link is still clean.
        case .interference: return ("Interference detected. Try another channel.", SPColor.error)
        case .congested:    return ("Channel is busy, but your link is clean.",
                                    SPColor.onSurfaceVariant)
        case .normal:       return nil
        }
    }

    private var rssi: Int? { model.rssi }
    private var snr: Int? { model.snr }
}
