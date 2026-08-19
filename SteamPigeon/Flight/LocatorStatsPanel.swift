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

    /// Tapping the panel speaks state and altitude — the same affordance Android has,
    /// and for the same reason: a rocket in flight is exactly when someone wants that
    /// without looking. Not gated on arm state (#36).
    var onTapSpeak: (() -> Void)?

    /// Bounds the panel may be dragged within — the map's own size.
    let containerSize: CGSize

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
            row("Dist: \(distanceM.map(String.init) ?? "--")")
            row(String(format: "AGL : %15.1f m", altitudeAglM))
            if let v = velocityMs { row(String(format: "Spd: %6.1f m/s", v)) }
            if let inc = inclinationDeg, let hdg = headingDeg {
                row(String(format: "Inc:%5.1f° Hdg:%5.1f°", inc, hdg))
            }
            if let a = accel {
                row(String(format: "Accl: %5.1f %5.1f %5.1f",
                           Double(a.x) / Self.g, Double(a.y) / Self.g, Double(a.z) / Self.g))
            }
            if let g = gyro {
                row(String(format: "Gyro: %5.0f %5.0f %5.0f",
                           Double(g.x) * Self.rad2deg, Double(g.y) * Self.rad2deg,
                           Double(g.z) * Self.rad2deg))
            }
            row(stateText)
            ForEach(Array(deployChannelText.enumerated()), id: \.offset) { _, text in
                row(text)
            }
            coordinates
        }
        .padding(8)
        .background(SPColor.mapOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background(                       // measure the panel so it can be clamped
            GeometryReader { proxy in
                Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(PanelSizeKey.self) { panelSize = $0 }
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
    }

    private func row(_ text: String) -> some View {
        Text(text)
            .font(SPFont.telemetry)
            .foregroundStyle(SPColor.onBackground)
            .lineLimit(1)
    }

    private var stateText: String {
        armed ? "\(flightState)" : "Disarmed"
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
        // Nothing measured yet. Android guards the same degenerate case with
        // `maxOf(marginPx, …)` because a not-yet-measured scaffold produced a lower
        // bound above the upper one and threw on returning to the map screen.
        guard container.width > 0, container.height > 0,
              panel.width > 0, panel.height > 0 else { return proposed }

        let minX = min(-(container.width - panel.width - margin * 2), 0)
        let minY = min(-(container.height - panel.height - margin * 2), 0)
        return CGSize(width: proposed.width.clamped(to: minX...0),
                      height: proposed.height.clamped(to: minY...0))
    }
}

private struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
