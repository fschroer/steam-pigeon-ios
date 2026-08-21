import SwiftUI
import MapLibre
import CoreLocation

/// Live map: the rocket, this phone, and the line between them.
///
/// MapLibre rather than MapKit, per ADR-0014 — the deciding factor is that neither
/// Google's nor Apple's SDK exposes an offline API, and offline satellite in
/// no-signal terrain is the thing recovery actually needs. Using MapKit here would
/// render today and have to be thrown away.
///
/// Per that ADR the marker, accuracy ring and track are **GeoJSON style layers**, not
/// annotations: same model as Android, and the only one the offline pack understands.
///
/// The bundled style loads from a `file:` URL, which is fine for **live** rendering.
/// The `http(s)`-only restriction in ADR-0014 applies to the offline *downloader*,
/// which rejects `asset:`/`file:` and stalls a region at "0/1 tiles". That is why
/// Android runs a localhost server for downloads — not needed until offline regions
/// land here.
struct FlightMapView: UIViewRepresentable {

    let rocket: CLLocationCoordinate2D?
    let phone: CLLocationCoordinate2D?
    /// Rocket GPS accuracy, metres; drawn as a ring so a loose fix reads as loose.
    let rocketAccuracyM: Double?
    /// This phone's accuracy — the user asked for the map precisely because this is
    /// significant, so it is drawn rather than described.
    let phoneAccuracyM: Double?
    /// Recorded ground track, oldest first.
    let track: [CLLocationCoordinate2D]
    /// Increment to request a re-frame. The camera otherwise fits once and then stays
    /// out of the way.
    var recentreToken: Int = 0
    /// Drives marker and accuracy-ring colour, as on Android.
    var markerState: RocketMarkerState = .live
    /// Reports the live camera out, so the compass rose can counter-rotate and the
    /// scale bar can size itself. Both are wrong at every zoom but one without it.
    /// Camera bearing to hold, or nil to leave rotation to the user. Non-nil is
    /// heading-up mode.
    var headingUpDeg: Double?
    /// Camera pitch, from the tilt mode.
    var pitchDeg: Double = 0
    /// Keep this coordinate centred, or nil to leave panning to the user.
    ///
    /// Only its NIL-ness is read: which point to frame is the filter's decision, and
    /// it frames the rocket AND the phone when both have fixes rather than the rocket
    /// alone — otherwise the phone leaves the screen exactly while you walk to the
    /// rocket, which is when the map is being looked at.
    var autoCentreOn: CLLocationCoordinate2D?
    /// Whether auto-zoom may drive the zoom.
    var autoZoom: Bool = false
    /// Closest zoom auto-zoom may frame to, from App Settings. Pinch is unbounded.
    var maxZoom: Int = AppSettings.zoomLimitDefault
    /// Changes when a camera control is tapped, which cancels the gesture backoff.
    var controlsToken: Int = 0

    var onCameraChange: ((_ bearing: Double, _ zoom: Double, _ centre: CLLocationCoordinate2D) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let url = Bundle.main.url(forResource: "satellite_style", withExtension: "json")
        let map = MLNMapView(frame: .zero, styleURL: url)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = context.coordinator
        context.coordinator.onCameraChange = onCameraChange
        // Match Android's uiSettings (MapLibreCompat.kt:423-431) exactly.
        map.logoView.isHidden = true            // avoids overlap with the app's overlays
        map.attributionButton.isHidden = true
        map.compassView.isHidden = true         // the app draws its own compass
        map.allowsTilting = false               // isTiltGesturesEnabled = false
        // Stated rather than left to MapLibre's defaults. These three ARE the
        // defaults today, so this changes nothing — but "the user can rotate the
        // map" is a parity requirement read off Android's uiSettings, not a
        // preference, and it should not silently depend on an SDK default.
        map.allowsRotating = true               // isRotateGesturesEnabled = true
        map.allowsZooming = true                // isZoomGesturesEnabled = true
        map.allowsScrolling = true              // isScrollGesturesEnabled = true
        // No maximumZoomLevel: the closest-zoom setting bounds AUTO-zoom only, and
        // setting it here would bound pinch too. Same reasoning as Android's.
        // North-up and flat. ADR-0014: tilt is compensated separately, so letting the
        // SDK account for it too corrects twice.
        map.setCenter(phone ?? rocket ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                      zoomLevel: 15, direction: 0, animated: false)
        context.coordinator.start(with: map)
        return map
    }

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.apply(to: map, rocket: rocket, phone: phone,
                                  rocketAccuracyM: rocketAccuracyM,
                                  phoneAccuracyM: phoneAccuracyM,
                                  track: track, recentreToken: recentreToken,
                                  markerState: markerState)
        context.coordinator.setCameraInputs(
            CameraInputs(fit: nil,
                         rocket: rocket,
                         phone: phone,
                         locatorAccuracyM: rocketAccuracyM ?? 0,
                         phoneAccuracyM: phoneAccuracyM,
                         autoCentre: autoCentreOn != nil,
                         autoZoom: autoZoom,
                         maxZoom: Double(maxZoom),
                         targetPitch: pitchDeg,
                         viewportWidthPx: 0,
                         screenScale: 1,
                         headingDeg: headingUpDeg),
            heading: headingUpDeg,
            controlsToken: controlsToken)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {

        private var styleReady = false
        private var pending: (() -> Void)?
        private var lastRecentreToken = 0
        var onCameraChange: ((Double, Double, CLLocationCoordinate2D) -> Void)?

        /// The map, so the display link can reach it without SwiftUI.
        private weak var mapView: MLNMapView?
        private var displayLink: CADisplayLink?
        private(set) var filter = CameraFilter()
        private var latestInputs = CameraInputs(
            fit: nil, rocket: nil, phone: nil, locatorAccuracyM: 0, phoneAccuracyM: nil,
            autoCentre: false, autoZoom: false, maxZoom: 20, targetPitch: 0,
            viewportWidthPx: 0, screenScale: 1)
        private var headingUp: Double?
        private var cachedFit: (key: FitKey, value: (CLLocationCoordinate2D, Double))?
        /// Android's `didInitialCenter`: the map renders before the first fix, so as
        /// soon as the phone's position is known — and while the rocket still has none
        /// — snap to it once. Without this the camera sits at its construction default
        /// until a rocket appears, which on a cold start is a view of null island.
        private var didInitialCentre = false

        /// Starts the per-frame camera. Paired with `stop()` so the link does not
        /// outlive the map — a CADisplayLink retains its target, so an unstopped one
        /// keeps this coordinator and the map alive for the life of the process.
        func start(with map: MLNMapView) {
            mapView = map
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tickCamera))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        deinit { displayLink?.invalidate() }

        /// When the user last touched the camera. Nil means "not recently".
        private var lastUserGesture: Date?
        private var lastControlsToken = 0

        /// How long the auto-camera stays out of the way after the last frame of a
        /// gesture. Android's `userGestureRecent` window, in `MapCameraController`.
        static let gestureBackoff: TimeInterval = 5

        /// True while the user owns the camera.
        ///
        /// Re-armed on every frame of a continuous gesture, so a slow pan or a long
        /// pinch is measured from when the finger stopped, not when it started.
        func userGestureRecent(now: Date = Date()) -> Bool {
            guard let last = lastUserGesture else { return false }
            return now.timeIntervalSince(last) <= Self.gestureBackoff
        }

        /// Everything that means "a finger moved this camera".
        ///
        /// Checked as a set rather than `== .gesturePan` because MapLibre reports a
        /// bitmask and a single pinch arrives as several bits at once.
        private static let gestureReasons: MLNCameraChangeReason = [
            .gesturePan, .gesturePinch, .gestureRotate, .gestureTilt,
            .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom,
        ]

        private func noteGesture(_ reason: MLNCameraChangeReason) {
            if !reason.intersection(Self.gestureReasons).isEmpty { lastUserGesture = Date() }
        }

        /// Seam for the tests: the delegate callbacks need a live `MLNMapView`, and
        /// what is worth pinning is which reasons count as the user's, not MapLibre's
        /// willingness to call us back.
        func noteGestureForTesting(_ reason: MLNCameraChangeReason) { noteGesture(reason) }

        /// Fires continuously while the camera moves, not only when it settles — the
        /// scale bar has to track a pinch as it happens, not snap afterwards.
        func mapView(_ map: MLNMapView, regionIsChangingWith reason: MLNCameraChangeReason) {
            noteGesture(reason)
            report(map)
        }

        func mapView(_ map: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason,
                     animated: Bool) {
            noteGesture(reason)
            report(map)
        }

        /// Drive the camera from the control toggles.
        ///
        /// Take the latest inputs from SwiftUI. The camera itself is driven by the
        /// display link, not from here.
        ///
        /// Android runs its filter from a `withFrameNanos` loop for the same reason:
        /// the filter has to tick every frame — that is what makes the motion smooth —
        /// but ticking it *as* composition made every frame a recomposition forever.
        func setCameraInputs(_ inputs: CameraInputs, heading: Double?, controlsToken: Int) {
            latestInputs = inputs
            headingUp = heading
            // A control tap is an explicit command and outranks the backoff, or
            // re-enabling auto-centre would appear dead until the window expired.
            if controlsToken != lastControlsToken {
                lastControlsToken = controlsToken
                lastUserGesture = nil
            }
        }

        /// One display frame of camera.
        ///
        /// **While the user is gesturing, and for five seconds after, this moves
        /// nothing** — Android's `MapCameraController` returns early on
        /// `userGestureRecent` for exactly this, and seeds the filter from the live
        /// camera on the way past so it resumes from where the fingers left it rather
        /// than snapping back.
        @objc func tickCamera() {
            guard let map = mapView, styleReady else { return }

            if userGestureRecent() {
                filter.seed(centre: map.centerCoordinate,
                            zoom: map.zoomLevel,
                            pitch: map.camera.pitch)
                return
            }

            var inputs = latestInputs
            inputs.fit = boundsFit(map, rocket: inputs.rocket, phone: inputs.phone)
            inputs.viewportWidthPx = Double(map.bounds.width) * Double(UIScreen.main.scale)
            inputs.screenScale = Double(UIScreen.main.scale)

            guard let solution = filter.tick(inputs) else { return }

            // Filtered, at CameraFilter.gainBearing — see the note there for why the
            // first pass left this out and why that was wrong.
            let direction = solution.bearing ?? map.direction

            // No animation: this IS the animation, one step per display frame. An
            // animated write per frame would queue 120 overlapping transitions a
            // second, each cancelling the last.
            let camera = MLNMapCamera(lookingAtCenter: solution.centre,
                                      altitude: MLNAltitudeForZoomLevel(solution.zoom,
                                                                        solution.pitch,
                                                                        solution.centre.latitude,
                                                                        map.bounds.size),
                                      pitch: solution.pitch,
                                      heading: direction)
            map.setCamera(camera, animated: false)
        }

        /// The SDK's own framing for rocket + phone, cached on the two fixes.
        ///
        /// **A pure query.** ADR-0014: never probe with a camera move to compute
        /// framing — MapLibre's GL thread renders continuously and draws that
        /// intermediate state, which is the auto-zoom wobble that ADR exists to record.
        ///
        /// Fitted NORTH-UP and FLAT. `cameraThatFitsCoordinateBounds` fits for the
        /// CURRENT bearing and pitch, which zooms further out — a rotated box needs a
        /// bigger viewport, and with heading-up on the bearing is arbitrary. Worse,
        /// tilt is already compensated by the filter's zoom correction, so letting the
        /// SDK account for it too corrects twice and over-zooms out. Hence the
        /// `camera:fittingCoordinateBounds:` overload with a zeroed camera, which is
        /// what Android's `getCameraForLatLngBounds(bounds, padding, 0.0, 0.0)` does.
        private func boundsFit(_ map: MLNMapView,
                               rocket: CLLocationCoordinate2D?,
                               phone: CLLocationCoordinate2D?) -> (CLLocationCoordinate2D, Double)? {
            guard let r = rocket, let p = phone else { return nil }
            let key = FitKey(rocket: r, phone: p, size: map.bounds.size)
            if let cached = cachedFit, cached.key == key { return cached.value }

            let padding = CameraFraming.boundsFitPadding(viewportWidth: Double(map.bounds.width),
                                                         viewportHeight: Double(map.bounds.height))
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: min(r.latitude, p.latitude),
                                           longitude: min(r.longitude, p.longitude)),
                ne: CLLocationCoordinate2D(latitude: max(r.latitude, p.latitude),
                                           longitude: max(r.longitude, p.longitude)))
            let flat = MLNMapCamera(lookingAtCenter: map.centerCoordinate,
                                    altitude: map.camera.altitude, pitch: 0, heading: 0)
            let fitted = map.camera(flat, fitting: bounds,
                                    edgePadding: UIEdgeInsets(top: padding.v, left: padding.h,
                                                              bottom: padding.v, right: padding.h))
            let zoom = MLNZoomLevelForAltitude(fitted.altitude, 0,
                                               fitted.centerCoordinate.latitude, map.bounds.size)
            let value = (fitted.centerCoordinate, zoom)
            cachedFit = (key, value)
            return value
        }

        /// What the fit depends on. Recomputing it per frame is a native call the
        /// filter does not need repeated; recomputing it per fix is what Android's
        /// `remember(...)` key does. The viewport is part of the key because the
        /// padding is derived from it, so a rotation has to re-ask.
        struct FitKey: Equatable {
            let rocketLat: Double, rocketLon: Double
            let phoneLat: Double, phoneLon: Double
            let size: CGSize
            init(rocket: CLLocationCoordinate2D, phone: CLLocationCoordinate2D, size: CGSize) {
                rocketLat = rocket.latitude; rocketLon = rocket.longitude
                phoneLat = phone.latitude; phoneLon = phone.longitude
                self.size = size
            }
        }

        private func report(_ map: MLNMapView) {
            onCameraChange?(map.direction, map.zoomLevel, map.centerCoordinate)
        }

        func mapView(_ map: MLNMapView, didFinishLoading style: MLNStyle) {
            styleReady = true
            pending?()
            pending = nil
        }

        func apply(to map: MLNMapView,
                   rocket: CLLocationCoordinate2D?,
                   phone: CLLocationCoordinate2D?,
                   rocketAccuracyM: Double?,
                   phoneAccuracyM: Double?,
                   track: [CLLocationCoordinate2D],
                   recentreToken: Int = 0,
                   markerState: RocketMarkerState = .live) {
            if recentreToken != lastRecentreToken {
                lastRecentreToken = recentreToken
                // An explicit ask outranks both the backoff and the latched anchors:
                // "put it back" has to mean now, not once GPS noise happens to cross a
                // deadband.
                lastUserGesture = nil
                if let map = mapView {
                    filter.seed(centre: map.centerCoordinate, zoom: map.zoomLevel,
                                pitch: map.camera.pitch)
                }
            }
            let work = { [weak self] in
                guard let self, let style = map.style else { return }
                self.draw(style: style, rocket: rocket, phone: phone,
                          rocketAccuracyM: rocketAccuracyM, phoneAccuracyM: phoneAccuracyM,
                          track: track, markerState: markerState)
                self.initialCentreIfNeeded(map, rocket: rocket, phone: phone)
            }
            if styleReady { work() } else { pending = work }
        }

        // MARK: - Layers

        private func draw(style: MLNStyle,
                          rocket: CLLocationCoordinate2D?,
                          phone: CLLocationCoordinate2D?,
                          rocketAccuracyM: Double?,
                          phoneAccuracyM: Double?,
                          track: [CLLocationCoordinate2D],
                          markerState: RocketMarkerState) {

            // Accuracy rings first, so the markers sit on top of them.
            upsertCircle(style, id: "phone-acc", centre: phone, radiusM: phoneAccuracyM,
                         colour: .systemBlue, opacity: 0.18)
            upsertCircle(style, id: "rocket-acc", centre: rocket, radiusM: rocketAccuracyM,
                         colour: markerState.color, opacity: 0.18)

            // The ground track.
            upsertLine(style, id: "track", coords: track, colour: RocketMarkerState.live.color, width: 2)

            upsertRocket(style, map: nil, at: rocket, state: markerState)
            upsertPoint(style, id: "phone", at: phone, colour: .systemBlue, radius: 5)
        }

        /// The rocket marker: the app's own glyph, tinted by trust state.
        ///
        /// Android registers three pre-tinted sprites (`IMG_ROCKET_FRESH/DEGRADED/STALE`)
        /// and switches `iconImage` between them, because MapLibre cannot tint a symbol
        /// layer's image at draw time. The same applies here, so the tint is baked into
        /// the registered image rather than set as a paint property.
        private func upsertRocket(_ style: MLNStyle, map: MLNMapView?,
                                  at coord: CLLocationCoordinate2D?,
                                  state: RocketMarkerState) {
            guard let coord else { removeLayer(style, id: "rocket"); return }

            let imageName = "rocket-\(state)"
            if style.image(forName: imageName) == nil,
               let tinted = Self.tintedRocket(state.color) {
                style.setImage(tinted, forName: imageName)
            }

            let feature = MLNPointFeature()
            feature.coordinate = coord
            let source = upsertSource(style, id: "rocket", shape: feature)

            if let existing = style.layer(withIdentifier: "rocket") as? MLNSymbolStyleLayer {
                existing.iconImageName = NSExpression(forConstantValue: imageName)
            } else {
                let layer = MLNSymbolStyleLayer(identifier: "rocket", source: source)
                layer.iconImageName = NSExpression(forConstantValue: imageName)
                layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
                layer.iconScale = NSExpression(forConstantValue: 0.5)
                layer.iconPitchAlignment = NSExpression(forConstantValue: "viewport")
                style.addLayer(layer)
            }
        }

        /// The rocket marker sprite, matching Android's `addRocketIcons`.
        ///
        /// Drawn TWICE: a white silhouette, then the tinted body inset by 8%, which
        /// gives the marker an outline. That outline is not decoration — a green
        /// marker over green tree canopy is invisible without it, and this map is used
        /// to walk to a landed rocket.
        private static let iconPx: CGFloat = 72

        private static func tintedRocket(_ colour: UIColor) -> UIImage? {
            guard let base = UIImage(named: "rocket") else { return nil }
            let size = CGSize(width: iconPx, height: iconPx)
            return UIGraphicsImageRenderer(size: size).image { _ in
                draw(base, colour: .white, in: size, inset: 0)
                draw(base, colour: colour, in: size, inset: iconPx * 0.08)
            }
        }

        /// Tint by drawing the glyph as a mask and filling through it — the equivalent
        /// of Android's `PorterDuff.Mode.SRC_IN` colour filter.
        private static func draw(_ image: UIImage, colour: UIColor, in size: CGSize, inset: CGFloat) {
            let rect = CGRect(x: inset, y: inset,
                              width: size.width - inset * 2, height: size.height - inset * 2)
            guard let ctx = UIGraphicsGetCurrentContext(), let cg = image.cgImage else { return }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            let flipped = CGRect(x: rect.minX, y: size.height - rect.maxY,
                                 width: rect.width, height: rect.height)
            ctx.clip(to: flipped, mask: cg)
            colour.setFill()
            ctx.fill(flipped)
            ctx.restoreGState()
        }

        private func upsertPoint(_ style: MLNStyle, id: String,
                                 at coord: CLLocationCoordinate2D?,
                                 colour: UIColor, radius: CGFloat) {
            guard let coord else { removeLayer(style, id: id); return }
            let feature = MLNPointFeature()
            feature.coordinate = coord
            let source = upsertSource(style, id: id, shape: feature)
            if style.layer(withIdentifier: id) == nil {
                let layer = MLNCircleStyleLayer(identifier: id, source: source)
                layer.circleColor = NSExpression(forConstantValue: colour)
                layer.circleRadius = NSExpression(forConstantValue: radius)
                layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                layer.circleStrokeWidth = NSExpression(forConstantValue: 1.5)
                style.addLayer(layer)
            }
        }

        private func upsertLine(_ style: MLNStyle, id: String,
                                coords: [CLLocationCoordinate2D],
                                colour: UIColor, width: CGFloat) {
            guard coords.count >= 2 else { removeLayer(style, id: id); return }
            var pts = coords
            let feature = MLNPolylineFeature(coordinates: &pts, count: UInt(pts.count))
            let source = upsertSource(style, id: id, shape: feature)
            if style.layer(withIdentifier: id) == nil {
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.lineColor = NSExpression(forConstantValue: colour)
                layer.lineWidth = NSExpression(forConstantValue: width)
                layer.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }
        }

        /// A metres-radius circle as a polygon. MapLibre's circle layers size in
        /// screen points, which would keep an accuracy ring the same size however far
        /// you zoom — the opposite of what a ring means.
        private func upsertCircle(_ style: MLNStyle, id: String,
                                  centre: CLLocationCoordinate2D?, radiusM: Double?,
                                  colour: UIColor, opacity: Double) {
            guard let centre, let radiusM, radiusM > 0 else { removeLayer(style, id: id); return }
            // 256 steps on the WGS84 equatorial radius, as Android uses. At 48 the
            // facets are visible on a large ring even before tile simplification.
            let steps = 256
            let earthR = 6_378_137.0
            let latRad = centre.latitude * .pi / 180
            var ring: [CLLocationCoordinate2D] = (0...steps).map { i in
                let theta = 2 * Double.pi * Double(i) / Double(steps)
                let dLat = (radiusM * sin(theta)) / earthR * (180 / .pi)
                let dLng = (radiusM * cos(theta)) / (earthR * cos(latRad)) * (180 / .pi)
                return CLLocationCoordinate2D(latitude: centre.latitude + dLat,
                                              longitude: centre.longitude + dLng)
            }
            let feature = MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count))
            let source = upsertSource(style, id: id, shape: feature)
            if style.layer(withIdentifier: id) == nil {
                let layer = MLNFillStyleLayer(identifier: id, source: source)
                layer.fillColor = NSExpression(forConstantValue: colour)
                layer.fillOpacity = NSExpression(forConstantValue: opacity)
                style.addLayer(layer)
            }
        }

        /// A shape source with simplification **off**.
        ///
        /// The defaults quietly wreck small geometry at high zoom: maximum zoom 18
        /// means past z18 the renderer rescales z18 tile geometry instead of
        /// re-tiling, and the default tolerance runs Douglas-Peucker simplification in
        /// tile units, dropping vertices. Together they turn the accuracy ring into a
        /// visible POLYGON, and worse the further you zoom in. Android raises the
        /// maximum zoom to 22 and disables simplification for exactly this reason.
        private func upsertSource(_ style: MLNStyle, id: String, shape: MLNShape) -> MLNShapeSource {
            if let existing = style.source(withIdentifier: id) as? MLNShapeSource {
                existing.shape = shape
                return existing
            }
            let source = MLNShapeSource(identifier: id, shape: shape, options: [
                .maximumZoomLevel: 22,
                .simplificationTolerance: 0,
            ])
            style.addSource(source)
            return source
        }

        private func removeLayer(_ style: MLNStyle, id: String) {
            if let l = style.layer(withIdentifier: id) { style.removeLayer(l) }
            if let s = style.source(withIdentifier: id) { style.removeSource(s) }
        }

        // MARK: - Camera

        /// One-shot centre on the phone, Android's `didInitialCenter`.
        ///
        /// Only while the ROCKET has no fix. Once it has one the filter frames both and
        /// this would fight it. Seeds the filter too, so the first filtered frame
        /// starts from the phone rather than dragging in from null island at 10% a
        /// frame.
        private func initialCentreIfNeeded(_ map: MLNMapView,
                                           rocket: CLLocationCoordinate2D?,
                                           phone: CLLocationCoordinate2D?) {
            guard !didInitialCentre, rocket == nil, let p = phone else { return }
            didInitialCentre = true
            map.setCenter(p, zoomLevel: 12, direction: map.direction, animated: false)
            filter.seed(centre: p, zoom: 12, pitch: map.camera.pitch)
        }
    }
}
