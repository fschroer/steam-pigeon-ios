import SwiftUI

/// The heads-up "point at the sky" view — Android's `CameraPreviewScreen`.
///
/// Android shows this **in landscape** instead of the map (`FlightMapScreen.kt:739`).
/// Rotating the phone is the gesture, on both platforms, so the manual can say "turn the
/// phone sideways" without branching.
///
/// It is an AR sight, not a panel of gauges: the back camera fills the screen, a
/// crosshair marks where it is aimed, and a ring marks where the rocket is against the
/// real sky — with an edge arrow instead when the rocket is outside the frame. Two HUD
/// scales along the bottom and right edge say how far off the aim is, in degrees. The
/// velocity gauge and the attitude render join them only while a flight is actually
/// under way.
///
/// A tap toggles the camera between 1× and its ceiling, as Android's does.
struct HeadsUpView: View {
    @ObservedObject var model: LinkViewModel
    /// The camera, owned by `RootView` so its setup survives a rotation — see the note
    /// there. This view still starts and stops it.
    @ObservedObject var camera: CameraPassthrough
    /// **Observed directly**, not reached through `model`. The sight is redrawn by the
    /// phone turning, and `LinkViewModel` does not republish its `phone`'s changes — so
    /// without this the marker moved only when a broadcast arrived, roughly once a
    /// second, against a crosshair that moves with the hand holding it.
    @ObservedObject var phone: PhoneLocation
    @Environment(\.displayScale) private var displayScale

    init(model: LinkViewModel, camera: CameraPassthrough) {
        self.model = model
        self.camera = camera
        self.phone = model.phone
    }

    // Android's colours, unchanged: red-pink locator, soft green crosshair, amber HUD.
    private let locatorColour   = Color(hex: 0xFF6080)
    private let crosshairColour = Color(hex: 0xC0FFC0)
    private let gaugeColour     = Color(hex: 0xFFC040)
    private let gaugeBackground = Color.black.opacity(0.5)

    /// Degrees shown either side of centre on both HUD scales, and the tick spacing.
    private let gaugeRange = 45.0
    private let tickMinor = 5.0
    private let tickMajor = 15

    private let stroke: CGFloat = 2
    private let labelSize: CGFloat = 10

    /// Where the camera is aimed, when there is a bearing to be had at all.
    ///
    /// Nil suppresses the marker and both pointers and leaves the scales standing: they
    /// are the reference frame, not a claim about where the rocket is.
    ///
    /// Android's `bearingValid = locatorFixUsable && compassUsable`, term for term —
    /// **and the compass term is a separate test, not a consequence of the first.** A
    /// non-nil `vector` means only that ADR-0022 stands behind the POSITION;
    /// `updateVector` publishes it under an unreliable compass and records the fact in
    /// `vectorSuppressedReason` instead, because the map quotes a distance, which no
    /// compass is involved in. ADR-0023 Decision 5 suppresses the **AR overlay**, and
    /// until this screen existed there was nothing here to suppress. Reading the position
    /// test as if it covered both is what put a confident marker on a patch of sky chosen
    /// by whatever iron is near the phone.
    private var deltas: (horizontal: Double, vertical: Double)? {
        guard let v = model.vector,
              phone.compassTrust != .unreliable,
              let azimuth = phone.cameraAzimuthDeg,
              let elevation = phone.cameraElevationDeg else { return nil }
        return (ARSight.horizontalDeltaDeg(locatorAzimuthDeg: v.azimuthDeg,
                                           cameraAzimuthDeg: azimuth),
                ARSight.verticalDeltaDeg(cameraElevationDeg: elevation,
                                         locatorElevationDeg: v.elevationDeg))
    }

    /// Android draws the flight instruments only while the rocket is flying AND the link
    /// is alive — a gauge fed by a frame that stopped arriving reads as a live number.
    private var showsFlightInstruments: Bool { model.isInFlight && model.isLocatorFresh }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SPColor.background

                // Present from the first frame, rather than waiting on `.running`:
                // attaching the preview to a session that is starting on the capture
                // queue is the main-thread wait this screen is trying not to take. It
                // shows nothing until the session delivers, which is what the background
                // behind it already looks like.
                if camera.status != .denied && camera.status != .unavailable {
                    CameraPassthroughView(camera: camera)
                }

                Canvas { ctx, size in draw(&ctx, size: size) }

                if showsFlightInstruments {
                    // Positioned where Android draws them: centres 100 dp in from the
                    // top-left and top-right corners, at its gauge radii.
                    VelocityGauge(speedMs: Double(model.telemetry?.velocityNed.magnitude ?? 0))
                        .frame(width: 160, height: 160)
                        .position(x: 100, y: 100)

                    AttitudeView(attitude: model.telemetry?.attitude
                                 ?? Quaternionf(w: 1, x: 0, y: 0, z: 0))
                        .frame(width: 156, height: 156)
                        .position(x: geo.size.width - 100, y: 100)
                }

                if let note = cameraNote {
                    Text(note)
                        .font(SPFont.bodySmall)
                        .foregroundStyle(SPColor.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .position(x: geo.size.width / 2, y: 28)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { camera.toggleZoom() }
        .onAppear {
            camera.start()
            // The sight is the only thing that wants a north-referenced attitude or a
            // 60 Hz one, so it asks for both here and gives them back on the way out.
            phone.beginCameraSensing()
        }
        .onDisappear {
            camera.stop()
            phone.endCameraSensing()
        }
    }

    /// What to say when there is no picture behind the sight.
    ///
    /// Android has no counterpart: it asks for the camera at launch beside location and
    /// Bluetooth, and its `CameraPreviewScreen` simply draws nothing at all — overlay
    /// included — while the provider is null. Here the overlay keeps working without a
    /// picture, because on iOS a refusal is a state the user can sit in indefinitely and
    /// the angles are still worth having. Recorded in `docs/UI_PARITY.md`.
    private var cameraNote: String? {
        switch camera.status {
        case .denied:      return "Camera access is off — Settings ▸ Steam Pigeon ▸ Camera"
        case .unavailable: return "No camera available"
        case .idle, .running: return nil
        }
    }

    // MARK: - The sight

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let cx = size.width / 2, cy = size.height / 2

        drawCrosshair(&ctx, cx: cx, cy: cy)
        drawMarker(&ctx, size: size)
        drawHorizontalScale(&ctx, size: size, cx: cx)
        drawVerticalScale(&ctx, size: size, cy: cy)
    }

    /// Four arms around a gap at the centre, so the aim point itself stays clear.
    private func drawCrosshair(_ ctx: inout GraphicsContext, cx: CGFloat, cy: CGFloat) {
        let gap: CGFloat = 50, arm: CGFloat = 25
        for (from, to) in [(CGPoint(x: cx, y: cy - gap - arm), CGPoint(x: cx, y: cy - gap)),
                           (CGPoint(x: cx + gap + arm, y: cy), CGPoint(x: cx + gap, y: cy)),
                           (CGPoint(x: cx, y: cy + gap + arm), CGPoint(x: cx, y: cy + gap)),
                           (CGPoint(x: cx - gap - arm, y: cy), CGPoint(x: cx - gap, y: cy))] {
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            ctx.stroke(path, with: .color(crosshairColour), lineWidth: stroke)
        }
    }

    private func drawMarker(_ ctx: inout GraphicsContext, size: CGSize) {
        guard let deltas else { return }
        let radius = ARSight.markerRadius
        switch ARSight.marker(horizontalDeltaDeg: deltas.horizontal,
                              verticalDeltaDeg: deltas.vertical,
                              size: size,
                              pointsPerDegree: ARSight.pointsPerDegree(screenScale: displayScale)) {
        case .circle(let centre):
            let box = CGRect(x: centre.x - radius, y: centre.y - radius,
                             width: radius * 2, height: radius * 2)
            ctx.stroke(Path(ellipseIn: box), with: .color(locatorColour), lineWidth: stroke)

        case .edgeArrow(let base, let direction):
            // Tip toward the locator, base across it.
            let arrow = ARSight.arrowSize
            let perpendicular = CGVector(dx: -direction.dy, dy: direction.dx)
            var path = Path()
            path.move(to: CGPoint(x: base.x + direction.dx * arrow,
                                  y: base.y + direction.dy * arrow))
            path.addLine(to: CGPoint(x: base.x + perpendicular.dx * arrow * 0.5,
                                     y: base.y + perpendicular.dy * arrow * 0.5))
            path.addLine(to: CGPoint(x: base.x - perpendicular.dx * arrow * 0.5,
                                     y: base.y - perpendicular.dy * arrow * 0.5))
            path.closeSubpath()
            ctx.fill(path, with: .color(locatorColour))
        }
    }

    /// Left/right error, along the bottom edge.
    private func drawHorizontalScale(_ ctx: inout GraphicsContext, size: CGSize, cx: CGFloat) {
        let width = size.width * 0.65
        let height: CGFloat = 22
        let left = (size.width - width) / 2
        let bottom = size.height - 16
        let top = bottom - height
        let midY = (top + bottom) / 2
        let perDegree = width / CGFloat(2 * gaugeRange)

        ctx.fill(Path(CGRect(x: left, y: top, width: width, height: height)),
                 with: .color(gaugeBackground))

        var degrees = -gaugeRange
        while degrees <= gaugeRange + 0.01 {
            let x = cx + CGFloat(degrees) * perDegree
            if x >= left && x <= left + width {
                let major = Int(degrees) % tickMajor == 0
                let length = height * (major ? 0.7 : 0.35)
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: midY - length / 2))
                tick.addLine(to: CGPoint(x: x, y: midY + length / 2))
                ctx.stroke(tick, with: .color(major ? gaugeColour : gaugeColour.opacity(0.45)),
                           lineWidth: major ? stroke : stroke * 0.5)
            }
            degrees += tickMinor
        }

        var zero = Path()
        zero.move(to: CGPoint(x: cx, y: top))
        zero.addLine(to: CGPoint(x: cx, y: bottom))
        ctx.stroke(zero, with: .color(.white), lineWidth: stroke * 1.5)

        if let deltas {
            let x = min(max(cx + CGFloat(deltas.horizontal) * perDegree, left), left + width)
            let triangle = height * 0.8
            var pointer = Path()
            pointer.move(to: CGPoint(x: x, y: top - 1))
            pointer.addLine(to: CGPoint(x: x - triangle * 0.5, y: top - triangle))
            pointer.addLine(to: CGPoint(x: x + triangle * 0.5, y: top - triangle))
            pointer.closeSubpath()
            ctx.fill(pointer, with: .color(locatorColour))
        }

        for label in labelDegrees {
            let x = cx + CGFloat(label) * perDegree
            guard x >= left && x <= left + width else { continue }
            ctx.draw(scaleLabel(label), at: CGPoint(x: x, y: bottom + 2), anchor: .top)
        }
    }

    /// Up/down error, along the right edge.
    private func drawVerticalScale(_ ctx: inout GraphicsContext, size: CGSize, cy: CGFloat) {
        let height = size.height * 0.55
        let width: CGFloat = 22
        let right = size.width - 16
        let left = right - width
        let top = cy - height / 2
        let bottom = cy + height / 2
        let midX = (left + right) / 2
        let perDegree = height / CGFloat(2 * gaugeRange)

        ctx.fill(Path(CGRect(x: left, y: top, width: width, height: height)),
                 with: .color(gaugeBackground))

        var degrees = -gaugeRange
        while degrees <= gaugeRange + 0.01 {
            let y = cy + CGFloat(degrees) * perDegree
            if y >= top && y <= bottom {
                let major = Int(degrees) % tickMajor == 0
                let length = width * (major ? 0.7 : 0.35)
                var tick = Path()
                tick.move(to: CGPoint(x: midX - length / 2, y: y))
                tick.addLine(to: CGPoint(x: midX + length / 2, y: y))
                ctx.stroke(tick, with: .color(major ? gaugeColour : gaugeColour.opacity(0.45)),
                           lineWidth: major ? stroke : stroke * 0.5)
            }
            degrees += tickMinor
        }

        var zero = Path()
        zero.move(to: CGPoint(x: left, y: cy))
        zero.addLine(to: CGPoint(x: right, y: cy))
        ctx.stroke(zero, with: .color(.white), lineWidth: stroke * 1.5)

        if let deltas {
            let y = min(max(cy + CGFloat(deltas.vertical) * perDegree, top), bottom)
            let triangle = width * 0.8
            var pointer = Path()
            pointer.move(to: CGPoint(x: left - 1, y: y))
            pointer.addLine(to: CGPoint(x: left - triangle, y: y - triangle * 0.5))
            pointer.addLine(to: CGPoint(x: left - triangle, y: y + triangle * 0.5))
            pointer.closeSubpath()
            ctx.fill(pointer, with: .color(locatorColour))
        }

        for label in labelDegrees {
            let y = cy + CGFloat(label) * perDegree
            guard y >= top && y <= bottom else { continue }
            ctx.draw(scaleLabel(label), at: CGPoint(x: left - 4, y: y), anchor: .trailing)
        }
    }

    /// Labelled at the ends, the halves and zero — and truncated, not rounded, so the
    /// halves read 22° as Android's `toInt()` prints them.
    private var labelDegrees: [Double] {
        [-gaugeRange, -gaugeRange / 2, 0, gaugeRange / 2, gaugeRange]
    }

    /// Android draws these with a raw `Paint` — the platform sans at 10 sp, in amber at
    /// 200/255 alpha.
    private func scaleLabel(_ degrees: Double) -> Text {
        Text("\(Int(degrees))°")
            .font(SPFont.chartLabel(size: labelSize))
            .foregroundColor(gaugeColour.opacity(200.0 / 255))
    }
}
