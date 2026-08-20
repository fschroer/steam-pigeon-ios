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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let url = Bundle.main.url(forResource: "satellite_style", withExtension: "json")
        let map = MLNMapView(frame: .zero, styleURL: url)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = context.coordinator
        // Match Android's uiSettings (MapLibreCompat.kt:423-431) exactly.
        map.logoView.isHidden = true            // avoids overlap with the app's overlays
        map.attributionButton.isHidden = true
        map.compassView.isHidden = true         // the app draws its own compass
        map.allowsTilting = false               // isTiltGesturesEnabled = false
        // North-up and flat. ADR-0014: tilt is compensated separately, so letting the
        // SDK account for it too corrects twice.
        map.setCenter(phone ?? rocket ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                      zoomLevel: 15, direction: 0, animated: false)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.apply(to: map, rocket: rocket, phone: phone,
                                  rocketAccuracyM: rocketAccuracyM,
                                  phoneAccuracyM: phoneAccuracyM,
                                  track: track, recentreToken: recentreToken,
                                  markerState: markerState)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {

        private var styleReady = false
        private var pending: (() -> Void)?
        /// Fit the camera once on the first real pair, then leave the camera to the
        /// user. Re-fitting on every 1 Hz update would fight anyone panning.
        private var didFit = false
        private var lastRecentreToken = 0

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
                didFit = false                      // an explicit ask re-arms the fit
            }
            let work = { [weak self] in
                guard let self, let style = map.style else { return }
                self.draw(style: style, rocket: rocket, phone: phone,
                          rocketAccuracyM: rocketAccuracyM, phoneAccuracyM: phoneAccuracyM,
                          track: track, markerState: markerState)
                self.fitIfNeeded(map, rocket: rocket, phone: phone)
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

            // The straight line between phone and rocket — the bearing, drawn. With a
            // loose phone fix this is the thing that shows how loose: the line swings
            // while the rocket marker sits still.
            if let p = phone, let r = rocket {
                upsertLine(style, id: "bearing", coords: [p, r], colour: .systemBlue, width: 2)
            } else {
                removeLayer(style, id: "bearing")
            }

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

        /// Frame both points once, using the **pure** bounds query.
        ///
        /// ADR-0014: never probe with `moveCamera` to compute framing. MapLibre's GL
        /// thread renders continuously and draws that intermediate state, which shows
        /// up as a persistent auto-zoom wobble.
        private func fitIfNeeded(_ map: MLNMapView,
                                 rocket: CLLocationCoordinate2D?,
                                 phone: CLLocationCoordinate2D?) {
            guard !didFit, let r = rocket, let p = phone else { return }
            didFit = true
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: min(r.latitude, p.latitude),
                                           longitude: min(r.longitude, p.longitude)),
                ne: CLLocationCoordinate2D(latitude: max(r.latitude, p.latitude),
                                           longitude: max(r.longitude, p.longitude)))
            let camera = map.cameraThatFitsCoordinateBounds(
                bounds, edgePadding: UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 60))
            map.setCamera(camera, animated: true)
        }
    }
}
