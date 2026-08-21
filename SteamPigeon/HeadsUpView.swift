import SwiftUI

/// The heads-up "point at the sky" view.
///
/// Android shows this **in landscape** instead of the map (`FlightMapScreen.kt:739`),
/// and it is where the velocity gauge and the attitude render live — not on the map.
/// Rotating the phone is the gesture, on both platforms, so the manual can say
/// "turn the phone sideways" without branching.
///
/// The camera passthrough that makes it a true AR overlay is not here yet; the
/// gauges and the bearing readout are. What is missing is the background, not the
/// instruments.
struct HeadsUpView: View {
    @ObservedObject var model: LinkViewModel

    var body: some View {
        ZStack {
            SPColor.background.ignoresSafeArea()

            HStack(alignment: .top) {
                // Speed, top-left — as Android places it.
                VelocityGauge(speedMs: Double(model.telemetry?.velocityNed.magnitude ?? 0))
                    .frame(width: 160, height: 160)
                    .padding(.leading, 20)

                Spacer()

                VStack(spacing: 6) {
                    if let v = model.vector {
                        Text("\(v.distanceM) m")
                            .font(SPFont.telemetryEmphasis(size: 34))
                            .foregroundStyle(SPColor.onBackground)
                        Text(String(format: "%.0f° %@", v.azimuthDeg, v.ordinal))
                            .font(SPFont.telemetry(size: 18))
                            .foregroundStyle(SPColor.secondary)
                    } else {
                        Text(model.vectorSuppressedReason ?? "No position")
                            .font(SPFont.bodySmall)
                            .foregroundStyle(SPColor.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                    }
                    if let t = model.telemetry {
                        Text(String(format: "%.0f m AGL", t.altitudeAgl))
                            .font(SPFont.telemetry(size: 16))
                            .foregroundStyle(SPColor.onSurfaceVariant)
                    }
                }
                .padding(.top, 20)

                Spacer()

                // Attitude, top-right — as Android places it.
                AttitudeView(attitude: model.telemetry?.attitude
                             ?? Quaternionf(w: 1, x: 0, y: 0, z: 0))
                    .frame(width: 150, height: 150)
                    .padding(.trailing, 20)
            }
            .padding(.top, 12)
        }
    }
}
