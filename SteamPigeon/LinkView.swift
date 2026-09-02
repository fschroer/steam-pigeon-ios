import SwiftUI

/// Bring-up screen for the CoreBluetooth transport.
///
/// Not the real UI — the SwiftUI app is step 3 of the ADR-0016 build order. This
/// exists to answer one question against real hardware: does the transport connect to
/// the receiver and deliver correctly framed packets? So it shows what would otherwise
/// only be visible in a debugger — what arrived, how big, and how the link is behaving.
/// Flight display plus the diagnostic screen, in tabs.
///
/// The bring-up screen stays reachable on purpose: it is what turned a bad-CRC count
/// into a firmware version skew, and that class of problem does not stop happening.
struct RootView: View {
    // Constructed ONCE, and measured to be — see the note in `BluetoothTransport.init`.
    // `@StateObject` wraps this expression in an autoclosure and evaluates it at most
    // once per view lifetime; it is `@ObservedObject var x = X()` that re-runs on every
    // init, which is a different declaration from this one.
    @StateObject private var model = LinkViewModel()
    @StateObject private var settings = AppSettings()

    @State private var showDiagnostics = false
    /// What the map screen wants shown. Owned HERE, not there, because this view is the
    /// one that presents — see `RootSheet`.
    @State private var mapSheet: MapSheet?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        // ONE main screen, as Android has: the map with its overlays. The earlier
        // Flight/Map/Link tab bar was scaffolding — Android has no tab bar, and its
        // other destinations live behind a navigation drawer, which maps to a
        // settings list rather than tabs.
        ZStack(alignment: .bottomTrailing) {
            // Landscape swaps the map for the heads-up view, exactly as Android does
            // (FlightMapScreen.kt:739). Rotating the phone is the gesture on both
            // platforms, so the manual needs no per-OS instruction.
            if isLandscape {
                HeadsUpView(model: model)
            } else {
                MapScreen(model: model, settings: settings, sheet: $mapSheet)
            }

            // TEMPORARY: the diagnostics screen has no Android counterpart. It stays
            // reachable because it is what turned a bad-CRC count into a firmware
            // version skew, but it belongs behind the settings list once that exists,
            // not on a control of its own.
            Button { showDiagnostics = true } label: {
                Image(systemName: "stethoscope").font(.footnote).padding(8)
            }
            .background(.ultraThinMaterial, in: Circle())
            .padding(.trailing, 12)
            .padding(.bottom, 12)
            .accessibilityLabel("Link diagnostics (temporary)")
        }
        // **Hold the screen awake while the main screen is what is being looked at.**
        //
        // Android does this with `FLAG_KEEP_SCREEN_ON` (`FlightMapScreen.kt`), for a
        // reason the system timeout cannot know about: watching the map and listening to
        // callouts is exactly the input-idle the timeout is built to catch, and it was
        // blanking the display mid-flight.
        //
        // **Scoped, not app-wide** — Android is emphatic about this, and the scoping is
        // the part that ports awkwardly. There, a menu destination replaces the map, so
        // the flag disposes with it. Here every destination is a sheet presented OVER a
        // map that stays alive, so scoping to `MapScreen` would hold the screen lit
        // through Application Settings, Flight Profiles and a long map download — the
        // cases Android deliberately excluded, where the phone is being used or left to
        // grind and the display is the largest single draw on the device.
        //
        // So the condition is "no sheet is up", which is the same set of screens Android
        // excludes, expressed the way this app's navigation actually works. Backgrounding
        // returns the device to its normal timeout on its own, as it does on Android.
        .onAppear { setIdleTimer(disabled: activeSheet.wrappedValue == nil) }
        .onChange(of: activeSheet.wrappedValue == nil) { setIdleTimer(disabled: $0) }
        // Never leave it held for an app that is no longer on screen.
        .onDisappear { setIdleTimer(disabled: false) }
        .preferredColorScheme(.dark)     // matches Android: read outdoors, not in a browser
        .tint(SPColor.primary)
        .background(SPColor.background)
        .onAppear { model.start() }
        // **THE app's only sheet** — the menu, a screen behind it, diagnostics, and the
        // password challenge, all through one presentation. A second `.sheet` anywhere
        // in this hierarchy, on this view or any descendant, reintroduces both failures:
        // the iOS 16 "already being presented" crash, and the quieter one where an
        // ancestor's sheet simply never appears because a descendant owns the
        // presentation. See `RootSheet`.
        .sheet(item: activeSheet) { current in
            switch current {
            case .challenge(let c):
                PasswordChallengeView(
                    challenge: c,
                    onSubmit: { model.submitPassword($0) },
                    onCancel: { model.declineChallenge() }
                )
                // **Not swipe-dismissible.** The two buttons mean different things —
                // one connects, the other puts the receiver back where it was — and a
                // swipe cannot express either. It used to land on `declineChallenge`,
                // so an accidental flick would silently revert a channel change the
                // user had just made deliberately.
                .interactiveDismissDisabled()
            case .map(let m):
                mapSheetContent(m)
            case .diagnostics:
                NavigationView { LinkView(model: model) }.navigationViewStyle(.stack)
            }
        }
    }

    /// One binding over every reason a sheet might be open, so there is one
    /// presentation to be in or out of.
    ///
    /// Answering a challenge does not dismiss anything: `model.challenge` goes nil,
    /// `RootSheet.active` falls back to whatever was underneath — a menu destination or
    /// diagnostics — and the sheet's content changes in place.
    ///
    /// **A dismissal never declines the challenge.** It cannot be one: the prompt
    /// refuses interactive dismissal, so reaching here means the user closed a menu
    /// destination or diagnostics. Treating a dismissal as a decline is what let a
    /// presentation the app did not control revert a channel behind the user's back.
    private var activeSheet: Binding<RootSheet?> {
        Binding(
            get: { RootSheet.active(challenge: model.challenge,
                                    map: mapSheet,
                                    showDiagnostics: showDiagnostics) },
            set: { newValue in
                guard newValue == nil else { return }
                showDiagnostics = false
                mapSheet = nil
            }
        )
    }

    /// Android's `addFlags` / `clearFlags` pair, in one place so the two can never
    /// drift apart — the failure mode of a held wake lock is a flat battery at the pad.
    private func setIdleTimer(disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    @ViewBuilder private func mapSheetContent(_ sheet: MapSheet) -> some View {
        switch sheet {
        case .menu:
            MenuView(
                destinations: MenuGating.destinations(
                    linkReady: model.state == .ready,
                    locatorActive: model.connectedLocatorId != nil,
                    armed: model.armed),
                // Swaps this sheet's content rather than dismissing it and presenting
                // another. `RootSheet.id` is constant, so SwiftUI has nothing to tear
                // down between the two.
                onSelect: { mapSheet = .destination($0) },
                onDismiss: { mapSheet = nil })
        case .destination(let destination):
            destinationView(destination)
        }
    }

    /// A screen reached from the menu. `Done` closes the sheet outright rather than
    /// returning to the menu: the menu is a way in, not a place, and one tap back to
    /// the map is what Android's drawer does too.
    private func destinationView(_ destination: MenuDestination) -> some View {
        NavigationView {
            Group {
                switch destination {
                case .communication:    CommunicationView(model: model)
                case .appSettings:      AppSettingsView(settings: settings)
                case .receiverSettings: ReceiverSettingsView(model: model)
                case .locatorSettings:  LocatorSettingsView(model: model)
                case .flightProfiles:   FlightProfilesView(model: model) { mapSheet = nil }
                case .downloadMap:      DownloadMapView(phone: model.phone)
                case .deploymentTest:   DeploymentTestView(model: model) { mapSheet = nil }
                case .appFlightLogs:    AppFlightLogsView(model: model) { mapSheet = nil }
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
                                mapSheet = nil
                            }
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

struct LinkView: View {
    @ObservedObject var model: LinkViewModel

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(model.state == .ready ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(model.stateLabel).font(.headline)
                }

                HStack(spacing: 16) {
                    stat("frames", "\(model.frameCount)")
                    stat("bad CRC", "\(model.badFrames)")
                    // ADR-0033. Inbound has "bad CRC"; this is its outbound
                    // counterpart, and it exists for the same reason — a write the
                    // framework discards is otherwise invisible on this platform.
                    stat("writes lost", "\(model.droppedWrites)")
                    stat("probes", "\(model.probesSent)")
                }

                if !model.conflictingLocatorIds.isEmpty || !model.unauthorizedLocatorIds.isEmpty {
                    Text("Other locators on this channel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(Array(model.conflictingLocatorIds).sorted(), id: \.self) { id in
                        HStack {
                            Text(String(format: "%08x  authorized, not connected", id))
                                .font(.caption2.monospaced())
                            Spacer()
                            Button("Connect") { model.switchTo(id) }
                                .font(.caption2)
                                .buttonStyle(.bordered)
                        }
                    }
                    ForEach(Array(model.unauthorizedLocatorIds).sorted(), id: \.self) { id in
                        Text(String(format: "%08x  no password held", id))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if let p = model.prelaunch {
                    Text("Locator — \(p.deviceName.isEmpty ? "(unnamed)" : p.deviceName)")
                        .font(.subheadline.weight(.semibold))
                    grid([
                        ("id", String(format: "%08x", p.locatorId)),
                        ("armed", p.armed ? "YES" : "no"),
                        ("GPS", "\(p.gpsStatus) · \(p.satellites) sats"),
                        ("position", String(format: "%.5f, %.5f", p.latitude, p.longitude)),
                        ("AGL", String(format: "%.1f m", p.altitudeAgl)),
                        ("battery", "\(p.locatorBatteryMv) mV"),
                        ("pad alert", "\(p.padAlert)"),
                        ("link", "rssi \(p.rssi) · snr \(p.snr) · floor \(p.noiseFloor)"),
                        ("receiver", "\(p.receiverName) ch \(p.channel)"),
                    ])
                }

                if let t = model.telemetry {
                    Text("Telemetry (armed)").font(.subheadline.weight(.semibold))
                    grid([
                        ("state", "\(t.flightState)"),
                        ("AGL", String(format: "%.1f m", t.altitudeAgl)),
                        ("vert speed", String(format: "%.1f m/s", -t.velocityNed.z)),
                        ("position", String(format: "%.5f, %.5f", t.latitude, t.longitude)),
                        ("GPS", "\(t.gpsStatus) · \(t.satellites) sats"),
                        ("link", "rssi \(t.rssi) · snr \(t.snr)"),
                    ])
                }

                if !model.countsByType.isEmpty {
                    Text("By message type").font(.subheadline.weight(.semibold))
                    ForEach(model.countsByType.sorted { $0.value > $1.value }, id: \.key) { type, n in
                        HStack {
                            Text(String(describing: type)).font(.caption.monospaced())
                            Spacer()
                            Text("\(n)").font(.caption.monospaced())
                        }
                    }
                }

                if !model.rejects.isEmpty {
                    Text("Rejected frames (bad CRC)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.rejects.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Text("Recent frames").font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.recent.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Spacer()

                HStack {
                    Button("Scan") { model.start() }
                        .buttonStyle(.borderedProminent)
                    Button("Disconnect") { model.disconnect() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("Steam Pigeon")
        }
        .navigationViewStyle(.stack)     // iOS 16: NavigationView, not NavigationStack
    }

    private func grid(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows, id: \.0) { label, value in
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .leading)
                    Text(value).font(.caption.monospaced())
                    Spacer()
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
