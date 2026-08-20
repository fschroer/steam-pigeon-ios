import SwiftUI

/// How the camera is tilted, mirroring Android's `MapTiltMode`.
///
/// The button shows the mode **currently in effect**; its label names the one a tap
/// will switch to. Getting that backwards makes the control feel like it lies.
enum MapTiltMode: CaseIterable {
    /// Flat, straight down.
    case flat
    /// Tilted toward the horizon, opening up as the rocket climbs.
    case altitude
    /// Tilt follows the physical pitch of the phone — raise it to look at the horizon.
    case followDevice

    var next: MapTiltMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// What a tap switches to, for the accessibility label.
    var nextDescription: String {
        switch next {
        case .flat:         return "2D view"
        case .altitude:     return "3D view"
        case .followDevice: return "phone-tilt view"
        }
    }

    /// MapLibre's own ceiling.
    static let maxPitch: Double = 60
    /// Beyond this much lean the map lies flat again. Android: 80, not 60 — a phone
    /// held at a natural reading angle is already well past 60.
    static let followFlatDeg: Double = 80

    /// Camera pitch for this mode.
    func pitch(altitudeAglM: Double, devicePitchDeg: Double) -> Double {
        switch self {
        case .flat:
            return 0
        case .altitude:
            // Opens up as the rocket climbs, so a high flight is seen obliquely.
            return min(max(45 + altitudeAglM / 30, 45), Self.maxPitch)
        case .followDevice:
            let fromUpright = min(max(abs(devicePitchDeg), 0), 90)
            guard fromUpright < Self.followFlatDeg else { return 0 }
            return min(max((1 - fromUpright / Self.followFlatDeg) * Self.maxPitch, 0), Self.maxPitch)
        }
    }
}

/// The view-mode and auto-framing controls, mirroring Android's column at the top
/// right of the map: four 48 pt icon buttons on the shared overlay background.
struct MapControlsColumn: View {
    @Binding var tiltMode: MapTiltMode
    @Binding var autoCentre: Bool
    @Binding var autoZoom: Bool
    /// Heading-up rotation. Android calls this `compassEnabled`.
    @Binding var headingUp: Bool
    /// Suppressed while the compass cannot be trusted — rotating the world to a
    /// heading the app does not believe is worse than not rotating it.
    let compassTrusted: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button { tiltMode = tiltMode.next } label: {
                tiltIcon.frame(width: 48, height: 48)
            }
            .accessibilityLabel("Switch to \(tiltMode.nextDescription)")

            toggle(systemName: "location.circle", on: $autoCentre,
                   onLabel: "Disable auto-center", offLabel: "Enable auto-center")

            toggle(systemName: "arrow.up.left.and.arrow.down.right", on: $autoZoom,
                   onLabel: "Disable auto-zoom", offLabel: "Enable auto-zoom")

            toggle(systemName: "safari", on: $headingUp,
                   onLabel: "Disable magnetic orientation",
                   offLabel: "Enable magnetic orientation",
                   enabled: compassTrusted)
        }
        .padding(.vertical, 4)
        .background(SPColor.mapOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var tiltIcon: some View {
        // The icon shows the mode IN EFFECT, not the one a tap selects.
        switch tiltMode {
        case .flat:
            Image("ic_view_2d").resizable().scaledToFit().frame(width: 32, height: 32)
        case .altitude:
            Image("ic_view_3d").resizable().scaledToFit().frame(width: 32, height: 32)
        case .followDevice:
            Image(systemName: "rotate.3d")
                .font(.system(size: 26))
                .foregroundStyle(SPColor.primary)
                .frame(width: 32, height: 32)
        }
    }

    /// An on/off control shown by opacity, as Android does — full white when active,
    /// 35% when not, so the state is legible without a second colour to learn.
    private func toggle(systemName: String, on: Binding<Bool>,
                        onLabel: String, offLabel: String,
                        enabled: Bool = true) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Image(systemName: systemName)
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(on.wrappedValue && enabled ? 1 : 0.35))
                .frame(width: 48, height: 48)
        }
        .disabled(!enabled)
        .accessibilityLabel(on.wrappedValue ? onLabel : offLabel)
    }
}
