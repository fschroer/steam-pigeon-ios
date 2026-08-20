import SwiftUI
import CoreLocation

/// The draggable telemetry panel that sits over the map, mirroring Android's
/// `LocatorStats`.
///
/// Fixed-width monospaced rows on a translucent rounded panel, positioned lower-right
/// by default and draggable anywhere within the map. Android formats each row with an
/// explicit field width so the numbers hold their columns as they change — the same
/// reason it uses a separate mono family — so the same `%` widths are used here.
struct LocatorStatsPanel: View {
    let deviceName: String
    let flightState: FlightStates
    let armed: Bool
    /// Android's `isInFlight`: armed, or a flight state other than WaitingLaunch.
    /// Gates speed, attitude and the state row — a disarmed rocket on the pad shows
    /// accelerometer readings instead.
    let inFlight: Bool
    let distanceM: Int?
    let altitudeAglM: Float
    let velocityMs: Float?
    let inclinationDeg: Double?
    let headingDeg: Double?
    let accel: Vec3f?
    let gyro: Vec3f?
    let latitude: Double
    let longitude: Double
    let deployChannelText: [String]
    /// Continuity per channel. A channel without it is drawn in the error colour.
    let deployChannelContinuity: [Bool]

    /// Tapping the panel speaks state and altitude — the same affordance Android has,
    /// and for the same reason: a rocket in flight is exactly when someone wants that
    /// without looking. Not gated on arm state (#36).
    var onTapSpeak: (() -> Void)?

    /// Bounds the panel may be dragged within — the map's own size.
    let containerSize: CGSize

    /// Bump to send the panel home.
    ///
    /// A deliberate safety net rather than a feature. This panel has now shipped
    /// twice with a drag that let it leave the screen, and the failure is
    /// unrecoverable without relaunching because the panel IS the telemetry. No unit
    /// test can catch "the SwiftUI measurement did not fire", so the fallback is an
    /// escape hatch that does not depend on the measurement being right.
    var homeToken: Int = 0

    @State private var offset: CGSize = .zero
    @State private var accumulated: CGSize = .zero
    @State private var panelSize: CGSize = .zero

    private func clamp(_ proposed: CGSize) -> CGSize {
        PanelDragBounds.clamp(proposed, panel: panelSize, container: containerSize)
    }

    private static let g = 9.80665
    private static let rad2deg = 180.0 / Double.pi

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Right-justified in a fixed field with units, matching Android's
            // "%15d" + " m" — the column is why the panel uses a mono face at all.
            row(distanceM.map { String(format: "Dist: %15d m", $0) }
                ?? String(format: "Dist: %15@ m", "unknown" as NSString))
            row(String(format: "AGL : %15.1f m", altitudeAglM))
            // In flight: speed and attitude. On the pad: what the IMU is reading.
            // Android switches between the two rather than showing both.
            if inFlight {
                if let v = velocityMs { row(String(format: "Spd: %6.1f m/s", v)) }
                if let inc = inclinationDeg, let hdg = headingDeg {
                    row(String(format: "Inc:%5.1f° Hdg:%5.1f°", inc, hdg))
                }
                row("\(flightState)")
            } else {
                if let a = accel {
                    row(String(format: "Accl: %5.1f %5.1f %5.1f",
                               Double(a.x) / Self.g, Double(a.y) / Self.g, Double(a.z) / Self.g))
                }
                if let g = gyro {
                    row(String(format: "Gyro: %5.0f %5.0f %5.0f",
                               Double(g.x) * Self.rad2deg, Double(g.y) * Self.rad2deg,
                               Double(g.z) * Self.rad2deg))
                }
            }
            ForEach(Array(deployChannelText.enumerated()), id: \.offset) { i, text in
                // Red where the app cannot see an igniter on that channel — which is
                // what someone checks before walking away from an armed rocket.
                row(text, colour: deployChannelContinuity.indices.contains(i)
                                  && !deployChannelContinuity[i]
                                  ? SPColor.error : SPColor.onBackground)
            }
            coordinates
        }
        .padding(8)
        .background(SPColor.mapOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background(                       // measure the panel so it can be clamped
            GeometryReader { proxy in
                Color.clear
                    .onAppear { panelSize = proxy.size }
                    .onChange(of: proxy.size) { panelSize = $0 }
            }
        )
        .offset(x: offset.width, y: offset.height)
        .gesture(
            DragGesture()
                .onChanged { g in
                    offset = clamp(CGSize(width: accumulated.width + g.translation.width,
                                          height: accumulated.height + g.translation.height))
                }
                .onEnded { _ in accumulated = offset }
        )
        .onTapGesture { onTapSpeak?() }
        .onChange(of: homeToken) { _ in
            offset = .zero
            accumulated = .zero
        }
    }

    private func row(_ text: String, colour: Color = SPColor.onBackground) -> some View {
        Text(text)
            .font(SPFont.telemetry)
            .foregroundStyle(colour)
            .lineLimit(1)
    }

    /// Tapping the coordinates opens them in Maps, as Android does.
    private var coordinates: some View {
        let lat = String(format: "%.5f", latitude)
        let lon = String(format: "%.5f", longitude)
        return Text("\(lat),\(lon)")
            .font(SPFont.telemetry)
            .foregroundStyle(SPColor.secondary)
            .lineLimit(1)
            .onTapGesture {
                guard latitude != 0 || longitude != 0 else { return }
                let label = deviceName.isEmpty ? "Rocket" : deviceName
                let encoded = label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Rocket"
                if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=\(encoded)") {
                    UIApplication.shared.open(url)
                }
            }
    }
}


/// Keeps the stats panel inside the map, as Android does with `coerceIn` on both axes.
///
/// Without it the panel drags off screen and cannot be recovered without relaunching —
/// and the panel *is* the telemetry, so losing it loses the readout. Extracted from the
/// view so the arithmetic is testable: this shipped once without bounds precisely
/// because it was buried in a gesture handler where nothing could check it.
///
/// The panel is laid out bottom-right, so its drag offsets travel **negative** from
/// there. The floors are the distance back to the top-left edge.
enum PanelDragBounds {
    static let margin: CGFloat = 8

    static func clamp(_ proposed: CGSize, panel: CGSize, container: CGSize) -> CGSize {
        // Nothing measured yet: REFUSE TO MOVE rather than passing the drag through.
        // The first version returned `proposed` here, which fails open — and when the
        // container size arrived late that was every drag, so the panel could be
        // pushed off screen and never recovered. Failing closed costs at worst a
        // panel that will not drag for one frame.
        //
        // Android guards the same degenerate case with `maxOf(marginPx, …)`, where an
        // unmeasured scaffold produced a lower bound above the upper one and threw.
        guard container.width > 0, container.height > 0,
              panel.width > 0, panel.height > 0 else { return .zero }

        let minX = min(-(container.width - panel.width - margin * 2), 0)
        let minY = min(-(container.height - panel.height - margin * 2), 0)
        return CGSize(width: proposed.width.clamped(to: minX...0),
                      height: proposed.height.clamped(to: minY...0))
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
