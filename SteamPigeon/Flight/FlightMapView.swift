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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let url = Bundle.main.url(forResource: "satellite_style", withExtension: "json")
        let map = MLNMapView(frame: .zero, styleURL: url)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = context.coordinator
        map.logoView.isHidden = false          // Esri attribution stays visible
        map.compassView.isHidden = false
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
                                  track: track, recentreToken: recentreToken)
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
                   recentreToken: Int = 0) {
            if recentreToken != lastRecentreToken {
                lastRecentreToken = recentreToken
                didFit = false                      // an explicit ask re-arms the fit
            }
            let work = { [weak self] in
                guard let self, let style = map.style else { return }
                self.draw(style: style, rocket: rocket, phone: phone,
                          rocketAccuracyM: rocketAccuracyM, phoneAccuracyM: phoneAccuracyM,
                          track: track)
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
                   recentreToken: Int = 0) {
            if recentreToken != lastRecentreToken {
                lastRecentreToken = recentreToken
                didFit = false                      // an explicit ask re-arms the fit
            }

            // Accuracy rings first, so the markers sit on top of them.
            upsertCircle(style, id: "phone-acc", centre: phone, radiusM: phoneAccuracyM,
                         colour: .systemBlue, opacity: 0.18)
            upsertCircle(style, id: "rocket-acc", centre: rocket, radiusM: rocketAccuracyM,
                         colour: .systemOrange, opacity: 0.18)

            // The ground track.
            upsertLine(style, id: "track", coords: track, colour: .systemOrange, width: 2)

            // The straight line between phone and rocket — the bearing, drawn. With a
            // loose phone fix this is the thing that shows how loose: the line swings
            // while the rocket marker sits still.
            if let p = phone, let r = rocket {
                upsertLine(style, id: "bearing", coords: [p, r], colour: .systemBlue, width: 2)
            } else {
                removeLayer(style, id: "bearing")
            }

            upsertPoint(style, id: "rocket", at: rocket, colour: .systemOrange, radius: 7)
            upsertPoint(style, id: "phone", at: phone, colour: .systemBlue, radius: 5)
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
            let steps = 48
            let metresPerDegLat = 111_320.0
            let metresPerDegLon = metresPerDegLat * cos(centre.latitude * .pi / 180)
            var ring: [CLLocationCoordinate2D] = (0...steps).map { i in
                let a = Double(i) / Double(steps) * 2 * .pi
                return CLLocationCoordinate2D(
                    latitude: centre.latitude + (radiusM * sin(a)) / metresPerDegLat,
                    longitude: centre.longitude + (radiusM * cos(a)) / max(metresPerDegLon, 1)
                )
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

        private func upsertSource(_ style: MLNStyle, id: String, shape: MLNShape) -> MLNShapeSource {
            if let existing = style.source(withIdentifier: id) as? MLNShapeSource {
                existing.shape = shape
                return existing
            }
            let source = MLNShapeSource(identifier: id, shape: shape, options: nil)
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
