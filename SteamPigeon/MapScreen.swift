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

            // ADR-0023 §5: LOW raises the prompt, it does not take the bearing away.
            if model.phone.compassTrust != .high {
                VStack {
                    Spacer()
                    Label(model.phone.compassTrust == .unreliable
                          ? "Compass unreliable — bearing withheld"
                          : "Compass needs calibration — figure-eight the phone",
                          systemImage: "location.slash")
                        .font(.caption)
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

    /// Bumped to ask the map to re-frame. A counter rather than a Bool so repeated
    /// taps each take effect — the camera otherwise fits once and then leaves the
    /// user's panning alone.
    @State private var recentre = 0

    private var banner: some View {
        HStack(spacing: 14) {
            if let v = model.vector {
                Label("\(v.distanceM) m", systemImage: "arrow.left.and.right")
                    .font(.callout.monospacedDigit().weight(.semibold))
                Text(String(format: "%.0f° %@", v.azimuthDeg, v.ordinal))
                    .font(.callout.monospacedDigit())
            } else {
                Text(model.vectorSuppressedReason ?? "no fix")
                    .font(.caption)
            }
            Spacer()
            if let acc = model.phone.horizontalAccuracyM {
                Text(String(format: "phone ±%.0f m", acc))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(acc <= 10 ? Color.secondary : Color.orange)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
