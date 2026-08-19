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
    let rssi: Int?
    let snr: Int?
    let deployChannelText: [String]
    /// The interference verdict, when there is one. Prose, not a column entry.
    let linkNote: (text: String, color: Color)?

    /// Tapping the panel speaks state and altitude — the same affordance Android has,
    /// and for the same reason: a rocket in flight is exactly when someone wants that
    /// without looking. Not gated on arm state (#36).
    var onTapSpeak: (() -> Void)?

    @State private var offset: CGSize = .zero
    @State private var accumulated: CGSize = .zero

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
            linkRow
            if let note = linkNote {
                Text(note.text)
                    .font(SPFont.labelSmall)
                    .foregroundStyle(note.color)
                    // Fixed width so a long verdict wraps instead of widening the
                    // panel — unconstrained it laid out on one line and dragged the
                    // whole block wider whenever the verdict changed.
                    .frame(width: 190, alignment: .leading)
                    .padding(.trailing, 4)
            }
        }
        .padding(8)
        .background(SPColor.mapOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .offset(x: offset.width, y: offset.height)
        .gesture(
            DragGesture()
                .onChanged { g in
                    offset = CGSize(width: accumulated.width + g.translation.width,
                                    height: accumulated.height + g.translation.height)
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

    @ViewBuilder private var linkRow: some View {
        HStack(spacing: 6) {
            if let r = rssi {
                Text(String(format: "RSSI %4d", r))
                    .font(SPFont.telemetry)
                    .foregroundStyle(RssiBand.color(r))
            }
            if let s = snr {
                Text(String(format: "SNR %3d", s))
                    .font(SPFont.telemetry)
                    .foregroundStyle(SnrBand.color(s))
            }
        }
    }
}
