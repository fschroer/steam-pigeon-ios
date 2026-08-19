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
                track: model.track
            )
            .ignoresSafeArea(edges: .bottom)

            banner
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
    }

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
