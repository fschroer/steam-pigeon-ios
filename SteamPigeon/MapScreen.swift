import SwiftUI

/// The live map tab.
///
/// The map exists to make bearing *checkable*. A distance and an azimuth are only as
/// good as the phone's own fix, and when that fix is loose the number cannot say so —
/// but two markers, two accuracy rings and the line between them can. That is why the
/// phone's accuracy circle is drawn rather than printed.
struct MapScreen: View {
    @ObservedObject var model: LinkViewModel

    var body: some View {
        ZStack(alignment: .top) {
            FlightMapView(
                rocket: model.rocketCoordinate,
                phone: model.phone.coordinate,
                rocketAccuracyM: model.rocketAccuracyM,
                phoneAccuracyM: model.phone.horizontalAccuracyM,
                track: model.track,
                recentreToken: recentre
            )
            .ignoresSafeArea(edges: .bottom)

            banner
                .padding(.horizontal, 12)
                .padding(.top, 8)

            // The telemetry panel, over the map as on Android. Positioned
            // lower-right by default and draggable, because whichever corner it
            // starts in will sometimes be the corner the rocket is in.
            if model.connectedLocatorId != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        statsPanel
                    }
                }
                .padding(8)
            }

            // ADR-0023 §5: LOW raises the prompt, it does not take the bearing away.
            if model.phone.compassTrust != .high {
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
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        recentre += 1
                    } label: {
                        Image(systemName: "scope").font(.title2).padding(10)
                    }
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(.trailing, 14)
                    .padding(.bottom, 60)
                    .accessibilityLabel("Re-centre on rocket and phone")
                }
            }
        }
    }

    @ViewBuilder private var statsPanel: some View {
        let p = model.prelaunch
        let t = model.telemetry
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
            rssi: t.map { Int($0.rssi) } ?? p.map { Int($0.rssi) },
            snr: t.map { Int($0.snr) } ?? p.map { Int($0.snr) },
            deployChannelText: (p?.deployChannelModes ?? []).enumerated().map { i, mode in
                DeployChannelText.line(channel: i + 1, mode: mode, config: p ?? PreLaunchData())
            },
            linkNote: nil,
            onTapSpeak: nil
        )
    }

    /// Bumped to ask the map to re-frame. A counter rather than a Bool so repeated
    /// taps each take effect — the camera otherwise fits once and then leaves the
    /// user's panning alone.
    @State private var recentre = 0

    private var banner: some View {
        HStack(spacing: 14) {
            if let v = model.vector {
                Label("\(v.distanceM) m", systemImage: "arrow.left.and.right")
                    .font(SPFont.telemetryBold(size: 16))
                Text(String(format: "%.0f° %@", v.azimuthDeg, v.ordinal))
                    .font(SPFont.telemetry(size: 16))
            } else {
                Text(model.vectorSuppressedReason ?? "no fix")
                    .font(SPFont.bodySmall)
            }
            Spacer()
            if let acc = model.phone.horizontalAccuracyM {
                Text(String(format: "phone ±%.0f m", acc))
                    .font(SPFont.telemetry(size: 11))
                    .foregroundStyle(acc <= 10 ? Color.secondary : Color.orange)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
