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
/// right of the map: 48 pt icon buttons on the shared overlay background.
///
/// **Order and behaviour are Android's**, read off `FlightMapScreen.kt`'s control
/// column rather than inferred: tilt, auto-centre, auto-zoom, magnetic orientation,
/// record track, reset track.
///
/// **Icons.** Android's are Compose `Icons.Default.*` — a library, not drawables in
/// the repo, so there is nothing for `Tools/vd2svg.py` to convert and these are the
/// nearest SF Symbols. Every one below is verified present in **iOS 13–16**, against
/// `CoreGlyphs.bundle/name_availability.plist`, because the deployment target is 16.0
/// and a symbol added later renders as a blank box on the phone rather than failing
/// the build. `SFSymbolAvailabilityTests` pins the names.
///
/// | Android | here | why |
/// |---|---|---|
/// | `MyLocation` | `scope` | both are a crosshair; `location.circle` was an arrow-in-circle and read as "navigate", not "centre on" |
/// | `ZoomOutMap` | `arrow.up.left.and.arrow.down.right` | no four-arrow expand glyph exists below iOS 17 |
/// | `Explore` | `safari` | both are a compass rose with a needle |
/// | `ScreenRotation` | `rotate.3d` | nearest available; names the phone-tilt mode it selects |
/// | `FiberManualRecord` | `circle.fill` | same filled disc |
/// | `Stop` | `stop.fill` | same filled square |
/// | `RestartAlt` | `arrow.counterclockwise` | same circular restart arrow |
///
/// The archived-path control (`History`) has no counterpart yet: Android offers it
/// only when a downloaded record exists, and flight-data download is not ported.
struct MapControlsColumn: View {
    @Binding var tiltMode: MapTiltMode
    @Binding var autoCentre: Bool
    @Binding var autoZoom: Bool
    /// Heading-up rotation. Android calls this `compassEnabled`.
    ///
    /// **Never disabled, whatever the compass is doing.** ADR-0023's trust verdict
    /// suppresses the BEARING — `MapScreen` withholds the heading when trust is
    /// `unreliable`, and Android does the same with `compassUsable`, which it applies
    /// to `bearingValid` and nowhere near this control. Greying the button out instead
    /// is a different claim: it says the MODE is unavailable, when what is unavailable
    /// is this moment's heading. Magnetic interference at startup is ordinary and
    /// passes; a control that arrives dead reads as a broken app, and the user cannot
    /// even express the preference. What tells them the compass is doubted is the
    /// calibration mark on the rose, which is where the doubted bearing is visible.
    @Binding var headingUp: Bool
    /// Whether new fixes are being appended to the track.
    @Binding var recording: Bool
    let onResetTrack: () -> Void
    /// Whether a downloaded archive record is available to switch to.
    var hasArchivedPath = false
    /// Whether the map is currently drawing it rather than the live track.
    @Binding var showArchivedPath: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button { tiltMode = tiltMode.next } label: {
                tiltIcon.frame(width: 48, height: 48)
            }
            .accessibilityLabel("Switch to \(tiltMode.nextDescription)")

            toggle(systemName: "scope", on: $autoCentre,
                   onLabel: "Disable auto-center", offLabel: "Enable auto-center")

            toggle(systemName: "arrow.up.left.and.arrow.down.right", on: $autoZoom,
                   onLabel: "Disable auto-zoom", offLabel: "Enable auto-zoom")

            toggle(systemName: "safari", on: $headingUp,
                   onLabel: "Disable magnetic orientation",
                   offLabel: "Enable magnetic orientation")

            // Android's tinting inverts here and it is not a slip: RED while
            // recording, dimmed while not. The other toggles mean "this mode is
            // engaged"; this one means "something is being written down", which is
            // the state worth spotting from across a field.
            Button { recording.toggle() } label: {
                Image(systemName: recording ? "stop.fill" : "circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(recording ? Color.red : .white.opacity(0.35))
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel(recording ? "Stop recording flight path"
                                          : "Start recording flight path")

            // Only offered once a record has been downloaded — otherwise there is no
            // archived track to switch to and the control would be a dead button.
            //
            // Cyan when engaged, matching Android's `COLOR_ARCHIVED_ACTIVE`, and the same
            // cyan the one-second markers use: both mean "this came off the archive".
            if hasArchivedPath {
                Button { showArchivedPath.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 24))
                        .foregroundStyle(showArchivedPath
                                         ? Color(red: 0, green: 0xE5 / 255.0, blue: 1)
                                         : .white.opacity(0.35))
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel(showArchivedPath ? "Show live GPS path"
                                                     : "Show archived (fused) path")
            }

            // Full white unconditionally — it is an action, not a state, so there is
            // no "off" for it to be dimmed into.
            Button(action: onResetTrack) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Reset flight path")
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
