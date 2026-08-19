import SwiftUI

/// The live map tab.
///
/// Layout mirrors Android's flight screen: the status column pinned top-left, the
/// draggable telemetry panel over the map, and the map filling everything.
struct MapScreen: View {
    @ObservedObject var model: LinkViewModel

    @State private var recentre = 0

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
                    track: model.track,
                    recentreToken: recentre
                )

                MapStatusPanel(
                    receiverName: nil,
                    connectionState: model.state,
                    receiverBatteryMv: model.prelaunch?.receiverBatteryMv,
                    locatorName: model.prelaunch?.deviceName,
                    satellites: model.telemetry?.satellites ?? model.prelaunch?.satellites,
                    gpsStatus: model.telemetry?.gpsStatus ?? model.prelaunch?.gpsStatus,
                    armed: model.telemetry?.armed ?? model.prelaunch?.armed ?? false,
                    locatorBatteryMv: model.prelaunch?.locatorBatteryMv,
                    rssi: rssi,
                    snr: snr,
                    linkNote: nil
                )
                .padding(8)

                if model.connectedLocatorId != nil {
                    statsPanel(in: proxy.size)
                }

                if model.phone.compassTrust != .high {
                    compassNote
                }

                recentreButton
            }
        }
        .ignoresSafeArea(edges: .bottom)
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
                    armed: t?.armed ?? p?.armed ?? false,
                    distanceM: model.vector?.distanceM,
                    altitudeAglM: t?.altitudeAgl ?? p?.altitudeAgl ?? 0,
                    // NED: down is positive, so a climb is the negation.
                    velocityMs: t.map { -$0.velocityNed.z },
                    inclinationDeg: nil,
                    headingDeg: nil,
                    accel: p?.accel,
                    gyro: p?.gyro,
                    latitude: t?.latitude ?? p?.latitude ?? 0,
                    longitude: t?.longitude ?? p?.longitude ?? 0,
                    deployChannelText: p.map { cfg in
                        cfg.deployChannelModes.enumerated().map { i, mode in
                            DeployChannelText.line(channel: i + 1, mode: mode, config: cfg)
                        }
                    } ?? [],
                    onTapSpeak: nil,
                    containerSize: container,
                    homeToken: recentre
                )
            }
        }
        .padding(8)
    }

    private var compassNote: some View {
        VStack {
            Spacer()
            Label(model.phone.compassTrust == .unreliable
                  ? "Compass unreliable — bearing withheld"
                  : "Compass needs calibration — figure-eight the phone",
                  systemImage: "location.slash")
                .font(SPFont.labelMedium)
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var recentreButton: some View {
        VStack {
            Spacer()
            HStack {
                Button { recentre += 1 } label: {
                    Image(systemName: "scope").font(.title2).padding(10)
                }
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel("Re-centre map and return the telemetry panel")
                Spacer()
            }
        }
        .padding(.leading, 14)
        .padding(.bottom, 60)
    }

    private var rssi: Int? {
        model.telemetry.map { Int($0.rssi) } ?? model.prelaunch.map { Int($0.rssi) }
    }
    private var snr: Int? {
        model.telemetry.map { Int($0.snr) } ?? model.prelaunch.map { Int($0.snr) }
    }
}
