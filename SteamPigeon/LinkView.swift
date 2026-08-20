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
    @StateObject private var model = LinkViewModel()
    @StateObject private var settings = AppSettings()

    @State private var showDiagnostics = false
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
                MapScreen(model: model, settings: settings)
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
        .sheet(isPresented: $showDiagnostics) {
            NavigationView { LinkView(model: model) }.navigationViewStyle(.stack)
        }
        .preferredColorScheme(.dark)     // matches Android: read outdoors, not in a browser
        .tint(SPColor.primary)
        .background(SPColor.background)
        .onAppear { model.start() }
        .sheet(item: Binding(
            get: { model.challenge },
            set: { if $0 == nil { model.declineChallenge() } }
        )) { c in
            PasswordChallengeView(
                challenge: c,
                onSubmit: { model.submitPassword($0) },
                onCancel: { model.declineChallenge() }
            )
        }
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
