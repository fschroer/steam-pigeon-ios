import SwiftUI
import CoreLocation

/// The live map tab.
///
/// Layout mirrors Android's flight screen: the status column pinned top-left, the
/// draggable telemetry panel over the map, and the map filling everything.
struct MapScreen: View {
    @ObservedObject var model: LinkViewModel
    @ObservedObject var settings: AppSettings

    init(model: LinkViewModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
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
    /// The menu and the screen it opens are ONE presentation — see `MapSheet`. They
    /// were two `.sheet` modifiers, and selecting a menu item dismissed the first
    /// while presenting the second in the same tick, which iOS 16 refuses.
    @State private var sheet: MapSheet?

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
                    track: model.trackCoordinates,
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
                        onResetTrack: { model.resetTrack() })
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
        .onDisappear { voice.padAlert.stop() }
        // THE screen's only sheet. Adding a second one here reintroduces the crash.
        .sheet(item: $sheet) { current in
            switch current {
            case .menu:
                MenuView(
                    destinations: MenuGating.destinations(
                        linkReady: model.state == .ready,
                        locatorActive: model.connectedLocatorId != nil,
                        armed: model.armed),
                    // Swaps this sheet's content rather than dismissing it and
                    // presenting another. `MapSheet.id` is constant, so SwiftUI has
                    // nothing to tear down between the two.
                    onSelect: { sheet = .destination($0) },
                    onDismiss: { sheet = nil })
            case .destination(let destination):
                destinationView(destination)
            }
        }
    }

    /// A screen reached from the menu. `Done` closes the sheet outright rather than
    /// returning to the menu: the menu is a way in, not a place, and one tap back to
    /// the map is what Android's drawer does too.
    private func destinationView(_ destination: MenuDestination) -> some View {
        NavigationView {
            Group {
                switch destination {
                case .appSettings:      AppSettingsView(settings: settings)
                case .receiverSettings: ReceiverSettingsView(model: model)
                case .locatorSettings:  LocatorSettingsView(model: model)
                case .flightProfiles:   FlightProfilesView(model: model) { sheet = nil }
                default:                NotYetBuiltView(destination: destination)
                }
            }
                .navigationTitle(destination.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        // Flight Profiles is two screens behind one flag, so Done steps
                        // the chart back to the record list first — what Android's
                        // up-arrow does there (`AppNavigation.kt`). Anywhere else, and
                        // from the list itself, it closes the sheet.
                        Button("Done") {
                            if destination == .flightProfiles,
                               model.flightProfileDataDisplayState {
                                model.returnToFlightProfileList()
                            } else {
                                sheet = nil
                            }
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
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
                    deviceName: p?.deviceName ?? "",
                    flightState: t?.flightState ?? .waitingLaunch,
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
                    receiverName: model.prelaunch?.receiverName,
                    connectionState: model.state,
                    // Pre-launch-only fields, aged on their own clock: the locator stops
                    // sending them the moment it is armed, and nothing is worse than a
                    // battery reading that is quietly the one from before the flight.
                    receiverBatteryMv: model.isPreLaunchFresh ? model.prelaunch?.receiverBatteryMv : nil,
                    locatorName: model.prelaunch?.deviceName,
                    satellites: model.satellites,
                    gpsStatus: model.gpsStatus,
                    armed: model.armed,
                    locatorBatteryMv: model.isPreLaunchFresh ? model.prelaunch?.locatorBatteryMv : nil,
                    rssi: rssi,
                    snr: snr,
                    linkNote: linkNote,
                    canArm: model.canSendArmCommand,
                    armPending: model.armCommandPending,
                    onRescan: { model.rescan() },
                    onToggleArmed: { model.toggleArmed() },
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
