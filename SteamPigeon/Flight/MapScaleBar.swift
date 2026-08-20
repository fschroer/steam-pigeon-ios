import SwiftUI

/// Map scale bar, mirroring Android's `GenericScaleBar`.
///
/// The length is computed from the bar's width in **points**, because
/// `metersPerPoint` is per logical pixel. Android had this multiplying by device
/// pixels, which overstated every distance by the display density — measured at 2.43×
/// on a 2.25-density phone. The bar is the only on-screen check a user has on how far
/// away anything is, so that read as the map lying about scale, and was reported that
/// way.
struct MapScaleBar: View {
    let zoom: Double
    let latitude: Double
    var width: CGFloat = 192

    /// Android's ladder: the bar always shows a number someone can use.
    private static let niceDistances = [1, 2, 5, 10, 20, 50, 100, 200, 500,
                                        1_000, 2_000, 5_000, 10_000, 20_000,
                                        50_000, 100_000, 200_000, 500_000]

    var body: some View {
        let totalMeters = MapScale.metersPerPoint(zoom: zoom, latitude: latitude) * Double(width)
        let niceM = Self.niceDistances.last { Double($0) <= totalMeters } ?? Self.niceDistances[0]
        let fraction = min(max(Double(niceM) / max(totalMeters, .leastNonzeroMagnitude), 0.05), 1)
        let label = niceM >= 1_000 ? "\(niceM / 1_000) km" : "\(niceM) m"

        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(SPFont.labelSmall)
                .foregroundStyle(SPColor.secondary)
            Canvas { context, size in
                let barW = size.width * fraction
                let y = size.height
                var path = Path()
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: y))          // left tick
                path.addLine(to: CGPoint(x: barW, y: y))       // baseline
                path.addLine(to: CGPoint(x: barW, y: 0))       // right tick
                context.stroke(path, with: .color(SPColor.primary), lineWidth: 2)
            }
            .frame(width: width, height: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityLabel("Map scale: \(label)")
    }
}

/// The app's own compass rose, with the ADR-0023 calibration mark on it.
///
/// The map SDK's compass is disabled (`isCompassEnabled = false` on Android) because
/// the app draws this one. The ∞ glyph sits **on the rose**, which is the only place
/// it means anything — it is marking the compass as untrustworthy, so it belongs on
/// the compass.
struct CompassRose: View {
    /// Map bearing, degrees. The rose counter-rotates so north stays north.
    let bearingDeg: Double
    let trust: CompassTrust
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Image("compass")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-bearingDeg))

            if trust != .high {
                // Android offsets this ~9 dp so it clears the rim and does not collide
                // with the south needle — measured off a screenshot, not derived.
                Text("∞")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(trust == .unreliable ? Color.red : Color.yellow)
                    .offset(y: 9)
                    // The glyph alone reads as "infinity" to a screen reader, which is
                    // not what it means here.
                    .accessibilityLabel(trust == .unreliable
                        ? "Compass unreliable — sweep the phone in a figure-eight to recalibrate"
                        : "Compass disturbed — sweep the phone in a figure-eight to recalibrate")
            }
        }
        .frame(width: size, height: size)
    }
}
