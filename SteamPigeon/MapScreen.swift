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
                    recentreToken: recentre,
                    markerState: model.markerState
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
                    linkNote: linkNote,
                    canArm: model.canSendArmCommand,
                    armPending: model.armCommandPending,
                    onRescan: { model.rescan() },
                    onToggleArmed: { model.toggleArmed() }
                )
                .padding(8)

                if model.connectedLocatorId != nil {
                    statsPanel(in: proxy.size)
                }

                // The app's own compass rose, carrying the ADR-0023 calibration mark,
                // and the scale bar — both bottom-left, clear of the stats panel.
                VStack(alignment: .leading, spacing: 6) {
                    Spacer()
                    CompassRose(bearingDeg: 0, trust: model.phone.compassTrust)
                    MapScaleBar(zoom: 15,
                                latitude: model.phone.coordinate?.latitude
                                       ?? model.rocketCoordinate?.latitude ?? 0)
                }
                .padding(.leading, 10)
                .padding(.bottom, 16)
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
                    armed: model.armed,
                    inFlight: model.isInFlight,
                    distanceM: model.vector?.distanceM,
                    altitudeAglM: t?.altitudeAgl ?? p?.altitudeAgl ?? 0,
                    // NED: down is positive, so a climb is the negation.
                    // Android shows total speed from the NED vector, not just the
                    // vertical component.
                    velocityMs: t.map { $0.velocityNed.magnitude },
                    inclinationDeg: t?.attitude.inclinationDeg,
                    headingDeg: t?.attitude.headingDeg,
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


    /// ADR-0019 verdict as prose. `Congested` is the quieter of the two: the channel
    /// is occupied but our packets are still arriving clean.
    private var linkNote: (text: String, color: Color)? {
        switch model.linkVerdict {
        case .interference: return ("Interference on this channel", SPColor.error)
        case .congested:    return ("Channel busy", SPColor.onSurfaceVariant)
        case .normal:       return nil
        }
    }

    private var rssi: Int? {
        model.telemetry.map { Int($0.rssi) } ?? model.prelaunch.map { Int($0.rssi) }
    }
    private var snr: Int? {
        model.telemetry.map { Int($0.snr) } ?? model.prelaunch.map { Int($0.snr) }
    }
}
