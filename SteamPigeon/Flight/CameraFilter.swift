import Foundation
import CoreLocation

/// What the auto-camera should be showing this frame.
struct CameraSolution: Equatable {
    var centre: CLLocationCoordinate2D
    /// The zoom to APPLY — already corrected for tilt.
    var zoom: Double
    var pitch: Double
    /// Camera bearing, or nil to leave rotation alone.
    var bearing: Double?

    static func == (a: CameraSolution, b: CameraSolution) -> Bool {
        a.centre.latitude == b.centre.latitude && a.centre.longitude == b.centre.longitude
            && a.zoom == b.zoom && a.pitch == b.pitch && a.bearing == b.bearing
    }
}

/// Everything one frame of filtering needs to know.
struct CameraInputs {
    /// The bounds-fit the SDK computed for rocket + phone, if both have fixes.
    /// `nil` when only one does — see `rocket`.
    var fit: (centre: CLLocationCoordinate2D, zoom: Double)?
    var rocket: CLLocationCoordinate2D?
    var phone: CLLocationCoordinate2D?
    var locatorAccuracyM: Double
    var phoneAccuracyM: Double?
    var autoCentre: Bool
    var autoZoom: Bool
    /// Closest zoom auto-zoom may frame to (App Settings). Pinch is NOT bound by it.
    var maxZoom: Double
    var targetPitch: Double
    var viewportWidthPx: Double
    var screenScale: Double
    /// Compass heading to hold, or nil when heading-up is off or the compass is not
    /// trusted (ADR-0023). Raw — the filter smooths it.
    var headingDeg: Double?
}

/// The per-frame camera filter, ported from Android's `CameraFilterState` and the
/// `tick` inside `MapCameraController`.
///
/// **Why a filter at all.** Both receivers keep issuing fresh fixes while nothing is
/// moving, so the framed centre wanders a few metres a second forever and the fitted
/// zoom breathes with it. Smoothing alone does not fix that — a filter with no deadband
/// tracks a random walk faithfully, just smoothly, and the imagery creeps under a rocket
/// lying still in a field.
///
/// **So the filter follows an ANCHOR, not the live target**, and re-latches the anchor
/// only once the live value has drifted past what the two receivers' combined error can
/// account for. Deadbanding the anchor rather than the filter output is what makes it
/// settle: the obvious alternative — skip the filter step whenever the live target is
/// within the band of the CAMERA — never converges, because the camera creeps toward the
/// target, re-enters the band a full band short of it, and stops there, permanently
/// trailing by up to that distance and stuttering along the boundary. Against a latched
/// anchor the filter always has a fixed point to reach, reaches it, and stops.
///
/// Pure and struct-shaped so a whole flight's worth of frames can be run in a test.
struct CameraFilter {

    // Android's gains, unchanged.
    static let gainTarget = 0.1
    static let gainZoom = 0.05
    static let gainTilt = 0.05
    /// Much slower than the others, and it has to be.
    ///
    /// This was left out on the first pass, on the reasoning that CoreLocation already
    /// smooths `trueHeading` and ADR-0023's trust hold gates it, so a second filter
    /// would only add lag. Reported from the phone as rotation being "very jerky", and
    /// the reasoning was wrong in a specific way: CoreLocation smooths the heading
    /// VALUE but delivers it in discrete updates a few times a second, while the camera
    /// is written every display frame. Holding a value for ~20 frames and then stepping
    /// it is exactly what a jerk is. At 0.01 the camera crosses most of a step in under
    /// a second, which is what makes the rotation continuous.
    static let gainBearing = 0.01

    private(set) var smoothedCentre = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    private(set) var smoothedZoom = 12.0
    private(set) var smoothedPitch = 0.0
    /// Nil until a heading is first offered, so heading-up starts AT the current
    /// heading rather than winding round to it from north at 1% a frame.
    private(set) var smoothedBearing: Double?

    /// The centre the camera is actually filtering toward. Nil means "no anchor yet",
    /// which latches on the next frame that has a target: at startup, after a gesture,
    /// and whenever a camera control is tapped.
    private(set) var anchorCentre: CLLocationCoordinate2D?
    /// The zoom's equivalent. Holds the **unclamped** fit — see `tick`.
    private(set) var anchorZoom: Double?

    private var seeded = false

    /// Whether the filter knows where the camera is yet. **Nothing moves until it does**
    /// (`tick` returns nil), so whoever owns a map has to seed it — see the note in
    /// `FlightMapView.Coordinator.tickCamera`, where a filter that reached the field
    /// unseeded left auto-centre, auto-zoom, tilt and heading-up all dead at once.
    var isSeeded: Bool { seeded }

    /// Adopt the live camera as the filter's state.
    ///
    /// Called while the user is gesturing, so that when the backoff expires the filter
    /// resumes from where their fingers left the camera rather than snapping back from
    /// wherever it had got to. The anchors go with it: a pan moves the camera somewhere
    /// the anchor knows nothing about, and keeping it would mean auto-centre resumed by
    /// measuring the band from a stale point — pan a short way and the drift back would
    /// never trip, leaving the map parked off the rocket with nothing to explain it.
    mutating func seed(centre: CLLocationCoordinate2D, zoom: Double, pitch: Double) {
        smoothedCentre = centre
        // Undo the tilt correction, so the correction applied on the way out does not
        // feed back into the next frame. Same formula the output uses, reversed.
        smoothedZoom = zoom + Self.zoomCorrection(forPitch: pitch)
        smoothedPitch = pitch
        smoothedBearing = nil
        anchorCentre = nil
        anchorZoom = nil
        seeded = true
    }

    /// Zoom given away to tilt, so a leaned camera still frames the same ground.
    static func zoomCorrection(forPitch pitch: Double) -> Double { pitch / 90 * 1.5 }

    /// Shortest signed turn from `from` to `to`, degrees in -180...180.
    ///
    /// The ±540 idiom: without it a heading crossing north reads as a 359° turn the
    /// long way round, and the camera spins most of a circle to go one degree.
    static func shortestTurn(from: Double, to: Double) -> Double {
        ((to - from + 540).truncatingRemainder(dividingBy: 360)) - 180
    }

    /// One frame. Returns the camera to apply, or nil when nothing should move.
    mutating func tick(_ input: CameraInputs) -> CameraSolution? {
        guard seeded else { return nil }

        smoothedPitch += (input.targetPitch - smoothedPitch) * Self.gainTilt
        // Driven by the SMOOTHED pitch so it fades in and out with the tilt transition
        // rather than snapping to zero the instant the mode changes.
        let correction = Self.zoomCorrection(forPitch: smoothedPitch)

        // Only frame the rocket if it has a fix — excluding 0,0 keeps the fit from
        // spanning to null island and dragging the zoom filter to world level.
        var autoTarget: CLLocationCoordinate2D?
        var autoZoomLevel: Double?
        if input.autoCentre || input.autoZoom, let rocket = input.rocket {
            if let fit = input.fit {
                autoTarget = fit.centre
                autoZoomLevel = fit.zoom
            } else {
                // No phone fix yet: centre on the rocket and do not touch the zoom.
                autoTarget = rocket
            }
        }

        if input.autoCentre, let autoTarget {
            let band = CameraFraming.viewportLimitedDeadbandM(
                CameraFraming.recenterDeadbandM(
                    locatorAccuracyM: input.locatorAccuracyM,
                    // nil means the phone is NOT part of the framing, so the target is
                    // the rocket alone and carries its full error.
                    phoneAccuracyM: input.fit == nil ? nil : input.phoneAccuracyM),
                viewportWidthPx: input.viewportWidthPx,
                // The zoom actually applied — post-correction — because that is what
                // decides how much ground is on screen.
                metersPerDevicePixel: CameraFraming.metersPerDevicePixel(
                    zoom: smoothedZoom - correction,
                    latitude: smoothedCentre.latitude,
                    scale: input.screenScale))

            if let anchor = anchorCentre {
                let drift = CameraFraming.metersBetween(
                    (anchor.latitude, anchor.longitude),
                    (autoTarget.latitude, autoTarget.longitude))
                if drift > band { anchorCentre = autoTarget }
            } else {
                anchorCentre = autoTarget
            }
        }

        if input.autoCentre, let follow = anchorCentre {
            smoothedCentre = CLLocationCoordinate2D(
                latitude: smoothedCentre.latitude
                    + (follow.latitude - smoothedCentre.latitude) * Self.gainTarget,
                longitude: smoothedCentre.longitude
                    + (follow.longitude - smoothedCentre.longitude) * Self.gainTarget)
        }

        // The anchor holds the UNCLAMPED fit while the output is clamped to the limit.
        // Comparing like with like is the point: clamping the anchor too would make
        // every fit past the limit compare equal, so a genuine move further in could
        // never re-latch once one had.
        if input.autoZoom, let autoZoomLevel {
            let separation: Double
            if let r = input.rocket, let p = input.phone {
                separation = CameraFraming.metersBetween((r.latitude, r.longitude),
                                                         (p.latitude, p.longitude))
            } else {
                separation = 0
            }
            let band = CameraFraming.autoZoomDeadbandLevels(
                locatorAccuracyM: input.locatorAccuracyM,
                phoneAccuracyM: input.phoneAccuracyM,
                separationM: separation)
            if let anchor = anchorZoom {
                if abs(autoZoomLevel - anchor) > band { anchorZoom = autoZoomLevel }
            } else {
                anchorZoom = autoZoomLevel
            }
        }

        // The closest-zoom limit lives HERE, on the filter, and nowhere else: the map
        // sets no maximum, so a pinch can always go closer, which is the point of the
        // setting. Inside the autoZoom branch deliberately — applied unconditionally it
        // would also claw back a manual zoom while auto-zoom is OFF, undoing a pinch
        // the moment the gesture window expired with nothing on screen to explain it.
        //
        // The ceiling carries + correction because the correction is subtracted on the
        // way out: this bounds the zoom actually APPLIED at maxZoom rather than the
        // pre-correction state, which under tilt would lose up to a whole level.
        if input.autoZoom, let follow = anchorZoom {
            smoothedZoom = min(smoothedZoom + (follow - smoothedZoom) * Self.gainZoom,
                               input.maxZoom + correction)
        }

        if let heading = input.headingDeg {
            if let current = smoothedBearing {
                let turn = Self.shortestTurn(from: current, to: heading)
                smoothedBearing = (current + turn * Self.gainBearing + 360)
                    .truncatingRemainder(dividingBy: 360)
            } else {
                smoothedBearing = heading      // adopt, do not wind round to it
            }
        } else {
            // Heading-up off: forget the smoothed value so re-enabling adopts the
            // live heading rather than resuming from a stale one.
            smoothedBearing = nil
        }

        return CameraSolution(centre: smoothedCentre,
                              zoom: smoothedZoom - correction,
                              pitch: smoothedPitch,
                              bearing: smoothedBearing)
    }
}
