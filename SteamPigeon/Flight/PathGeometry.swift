import CoreLocation
import Foundation

/// A point in a curtain or marker ring. Its own type rather than
/// `CLLocationCoordinate2D` so the geometry stays `Equatable`, testable and free of
/// MapLibre — the conversion happens at the map boundary.
struct PathCoord: Equatable {
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// One extruded prism: a thin closed rectangle in plan view, raised from the ground to
/// `heightM`.
struct ExtrudedQuad: Equatable {
    /// Closed — the first point is repeated last, as GeoJSON requires.
    var ring: [PathCoord]
    var heightM: Float
}

/// The ground track, the altitude curtain standing on it, and the one-second markers.
///
/// Carried as one value so the whole expensive pass happens in a single hop, as Android's
/// `PathGeometry` does.
struct PathGeometry: Equatable {
    var track: [PathCoord]
    var curtain: [ExtrudedQuad]
    var ticks: [ExtrudedQuad]

    static let empty = PathGeometry(track: [], curtain: [], ticks: [])
}

/// Builds every piece of flight-path geometry.
///
/// Pure, and safe to call off the main actor — nothing here touches the map. Ported from
/// Android's `MapLibreCompat.buildPathGeometry` and the three builders under it.
enum FlightPathGeometry {

    // MARK: - Curtain constants (Android's, value for value)

    /// **Lever 1 — riser height.** MapLibre's line layer is strictly ground-plane, so
    /// lifting the track into the air means extruded polygons: one quad per segment,
    /// extruded from the ground to that segment's AGL. `fill-extrusion-height` is constant
    /// per feature and there is no sloped-top option, so the wall's top edge is necessarily
    /// a staircase; smoothness comes from splitting each interval by **altitude change**
    /// rather than a fixed count. A fixed count divides the *ground* run evenly, which is
    /// the wrong axis: on a near-vertical boost the track barely advances while altitude
    /// climbs hundreds of metres, so risers stay tall however finely the run is chopped.
    static let curtainTargetRiserM: Float = 0.25

    /// Backstop on total sub-quads, relaxing the riser only if a path would otherwise emit
    /// an unreasonable number of features.
    ///
    /// Deliberately high enough NOT to bind on a normal flight, because the term that
    /// drives it — summed |altitude change| — cannot tell signal from noise, and that bit
    /// hard on Android: raw baro at the 20 Hz archive cadence jitters a few metres sample
    /// to sample, and summing absolute differences over ~2000 samples turned that into
    /// thousands of metres. A 122 m flight measured 244 m of variation clean but 4000 m
    /// with ±3 m of noise, which inflated the riser from 0.25 m to ~2 m — the budget
    /// silently undoing the smoothing it was introduced alongside.
    static let curtainMaxQuads: Float = 20_000

    /// Per-interval safety valve, so one wild altitude jump — a garbled fix, or the first
    /// sample after a dropout — cannot consume the whole budget itself.
    static let curtainMaxSubdivisions = 512

    /// Half-width of each curtain quad, in metres. Wide enough that the wall stays visible
    /// edge-on when the camera looks along the track, narrow enough not to misrepresent the
    /// track's ground position.
    static let curtainHalfWidthM = 0.75

    /// A segment whose peak is below this contributes no useful height information and
    /// would just add z-fighting clutter over the ground line.
    static let curtainMinAltM: Float = 0.5

    // MARK: - Second-marker constants

    /// Full-height posts standing on the ground track up to the path's altitude at each
    /// whole second of recording, turning the curtain into a ruler you can read climb rate
    /// off directly.
    static let tickIntervalMs: Int64 = 1_000

    /// Wider than the curtain, and given a little length along the track, so the post
    /// protrudes from the wall on both faces. Coincident geometry would z-fight instead of
    /// reading as a mark.
    static let tickHalfWidthM = 1.6
    static let tickHalfLengthM = 0.4

    /// Ceiling on marker count. A recording left running for an hour would otherwise emit
    /// 3600 posts, all rebuilt on every telemetry message.
    static let tickMaxCount = 600

    private static let metersPerDegLat = 111_320.0

    // MARK: - Building

    static func build(_ path: [TrackPoint]) -> PathGeometry {
        PathGeometry(
            track: path.count >= 2
                ? path.map { PathCoord(latitude: $0.latitude, longitude: $0.longitude) }
                : [],
            curtain: altitudeCurtain(path),
            ticks: secondMarkers(path))
    }

    /// A downloaded archive record as a map path.
    ///
    /// The archive stores position in **radians**, and the whole feature rests on this
    /// conversion: treating them as degrees would put a Seattle-area flight at 0.83°N
    /// 2.14°W — in the Atlantic, ~5000 km off — with no error raised anywhere.
    ///
    /// A sample with no fix is dropped rather than plotted. A zero coordinate is not a
    /// position on the Gulf of Guinea, it is "no fix", and a record starts before GPS
    /// necessarily has a lock — so plotting it would run the path to null island and wreck
    /// the map's bounds. Non-finite and out-of-range coordinates go the same way.
    ///
    /// Times carry through as **real** time: the archive clock is GPS-disciplined and counts
    /// from the record start, so an archived path's one-second markers mean what they say.
    /// These points are deliberately not flagged `timeSynthetic` — that flag is for a track
    /// restored from a recording made before capture times existed.
    ///
    /// Ported from Android's `RocketViewModel.archivedPathPoints`.
    static func archivedPathPoints(_ samples: [FlightSample]) -> [TrackPoint] {
        samples.compactMap { s in
            let lat = s.latRad * 180 / .pi
            let lon = s.lonRad * 180 / .pi
            let usable = lat.isFinite && lon.isFinite
                && abs(lat) <= 90 && abs(lon) <= 180
                && (lat != 0 || lon != 0)
            guard usable else { return nil }
            return TrackPoint(latitude: lat, longitude: lon,
                              altitudeM: s.altitudeM,
                              timestampMs: Int64(s.timestampMs))
        }
    }

    /// Builds the altitude curtain: a wall of extruded quads hanging from the flight path
    /// down to the ground, whose top edge traces the altitude profile.
    ///
    /// Returns nothing for a path with no meaningful altitude, so a pad-bound or
    /// ground-level track does not draw a degenerate wall.
    static func altitudeCurtain(_ path: [TrackPoint]) -> [ExtrudedQuad] {
        guard path.count >= 2 else { return [] }

        var out: [ExtrudedQuad] = []
        let spline = PathSpline(path)
        let riser = curtainRiser(path)

        for i in 0..<(path.count - 1) {
            let subdivisions = curtainSubdivisions(from: path[i].altitudeM,
                                                   to: path[i + 1].altitudeM,
                                                   riserM: riser)
            for s in 0..<subdivisions {
                let t0 = Double(s) / Double(subdivisions)
                let t1 = Double(s + 1) / Double(subdivisions)

                let lat0 = spline.latitude(at: i, t: t0)
                let lon0 = spline.longitude(at: i, t: t0)
                let lat1 = spline.latitude(at: i, t: t1)
                let lon1 = spline.longitude(at: i, t: t1)

                // The mean of its endpoints, so the staircase straddles the true profile
                // instead of lagging it.
                let height = (spline.altitude(at: i, t: t0) + spline.altitude(at: i, t: t1)) / 2
                if height < curtainMinAltM { continue }

                // Longitude degrees shrink by cos(latitude), so convert to metres before
                // taking the normal or the wall skews with latitude.
                let cosLat = max(cos(lat0 * .pi / 180), 1e-6)
                let dxM = (lon1 - lon0) * metersPerDegLat * cosLat
                let dyM = (lat1 - lat0) * metersPerDegLat
                let lenM = (dxM * dxM + dyM * dyM).squareRoot()
                // Zero-length sub-segment (rocket stationary): nothing to extrude.
                if lenM < 1e-6 { continue }

                let nxM = -dyM / lenM * curtainHalfWidthM
                let nyM = dxM / lenM * curtainHalfWidthM
                let dLon = nxM / (metersPerDegLat * cosLat)
                let dLat = nyM / metersPerDegLat

                out.append(ExtrudedQuad(ring: [
                    PathCoord(latitude: lat0 + dLat, longitude: lon0 + dLon),
                    PathCoord(latitude: lat1 + dLat, longitude: lon1 + dLon),
                    PathCoord(latitude: lat1 - dLat, longitude: lon1 - dLon),
                    PathCoord(latitude: lat0 - dLat, longitude: lon0 - dLon),
                    PathCoord(latitude: lat0 + dLat, longitude: lon0 + dLon),
                ], heightM: height))
            }
        }
        return out
    }

    /// How many pieces one telemetry interval must be split into to keep each riser under
    /// `riserM`.
    ///
    /// Level flight needs exactly one quad — subdividing it would emit identical heights
    /// and buy nothing — so the floor is 1, not a fixed count.
    static func curtainSubdivisions(from: Float, to: Float, riserM: Float) -> Int {
        let n = Int((abs(to - from) / riserM).rounded(.up))
        return min(max(n, 1), curtainMaxSubdivisions)
    }

    /// Riser height to aim for across `path`: ``curtainTargetRiserM``, relaxed only if
    /// ``curtainMaxQuads`` would otherwise be exceeded.
    static func curtainRiser(_ path: [TrackPoint]) -> Float {
        guard path.count >= 2 else { return curtainTargetRiserM }
        var variation: Float = 0
        for i in 0..<(path.count - 1) {
            variation += abs(path[i + 1].altitudeM - path[i].altitudeM)
        }
        return max(curtainTargetRiserM, variation / curtainMaxQuads)
    }

    /// Builds the one-second markers: contrasting posts standing on the ground track, each
    /// extruded from the ground to the path's interpolated altitude at a whole second of
    /// recording time.
    ///
    /// Marks are placed at real elapsed time from the first recorded fix, found by
    /// interpolating between the two samples that bracket each boundary — so they stay on
    /// true seconds through a dropped packet or a variable radio interval, which counting
    /// samples would not.
    ///
    /// The mark at t=0 is skipped: the rocket is on the pad, so its post would have no
    /// height to draw. Points carrying a synthetic timestamp are stepped over, and elapsed
    /// time is measured from the first *real* fix — so a path that mixes a restored prefix
    /// with newly received points still marks the live portion correctly instead of
    /// anchoring to a placeholder zero.
    static func secondMarkers(_ path: [TrackPoint]) -> [ExtrudedQuad] {
        guard path.count >= 2 else { return [] }

        guard let firstReal = path.firstIndex(where: { !$0.timeSynthetic }),
              let lastReal = path.lastIndex(where: { !$0.timeSynthetic }),
              lastReal > firstReal
        else { return [] }   // nothing carries a real capture time

        let startMs = path[firstReal].timestampMs
        let endMs = path[lastReal].timestampMs
        // Non-monotonic timestamps (a clock adjustment mid-recording) leave no meaningful
        // time axis to mark up.
        guard endMs > startMs else { return [] }

        var out: [ExtrudedQuad] = []
        // The same curve the curtain is built from. Interpolating a mark linearly while the
        // wall beside it curves would stand the post's top off the wall's top edge — by
        // metres, where the two disagree most.
        let spline = PathSpline(path)
        var index = firstReal      // walks forward with the marks; both are ordered
        var elapsed = tickIntervalMs

        while startMs + elapsed <= endMs && out.count < tickMaxCount {
            let markMs = startMs + elapsed
            elapsed += tickIntervalMs

            while index < path.count - 2 && path[index + 1].timestampMs < markMs { index += 1 }
            let a = path[index]
            let b = path[index + 1]
            // Either endpoint's time is a placeholder, so where this second falls between
            // them is unknowable.
            if a.timeSynthetic || b.timeSynthetic { continue }

            let span = Double(b.timestampMs - a.timestampMs)
            let f = span > 0 ? min(max(Double(markMs - a.timestampMs) / span, 0), 1) : 0

            let alt = spline.altitude(at: index, t: f)
            if alt < curtainMinAltM { continue }

            let lat = spline.latitude(at: index, t: f)
            let lon = spline.longitude(at: index, t: f)

            // Orient the post across the direction of travel, matching the curtain.
            let cosLat = max(cos(lat * .pi / 180), 1e-6)
            let dxM = (b.longitude - a.longitude) * metersPerDegLat * cosLat
            let dyM = (b.latitude - a.latitude) * metersPerDegLat
            let lenM = (dxM * dxM + dyM * dyM).squareRoot()
            // A rocket descending under canopy in still air can hold one lat/lon across the
            // whole interval. It still has altitude worth marking, so fall back to a
            // north-aligned post rather than dropping the mark.
            let ux = lenM < 1e-6 ? 0.0 : dxM / lenM
            let uy = lenM < 1e-6 ? 1.0 : dyM / lenM

            let alongX = ux * tickHalfLengthM
            let alongY = uy * tickHalfLengthM
            let acrossX = -uy * tickHalfWidthM
            let acrossY = ux * tickHalfWidthM

            func corner(_ sx: Double, _ sy: Double) -> PathCoord {
                let mx = alongX * sx + acrossX * sy
                let my = alongY * sx + acrossY * sy
                return PathCoord(latitude: lat + my / metersPerDegLat,
                                 longitude: lon + mx / (metersPerDegLat * cosLat))
            }

            out.append(ExtrudedQuad(
                ring: [corner(-1, 1), corner(1, 1), corner(1, -1), corner(-1, -1), corner(-1, 1)],
                heightM: alt))
        }
        return out
    }
}

/// Smooth interpolation through the recorded points, replacing straight chords.
///
/// Cubic Hermite throughout, but with **different tangent rules for altitude and for
/// position**, because they have different failure modes.
///
/// *Altitude* uses Fritsch–Carlson monotone tangents. A plain Catmull-Rom spline overshoots
/// near a sharp extremum, and the sharpest feature in a flight profile is apogee — so it
/// would draw the rocket higher than it ever flew, and a reader measuring apogee off the
/// curtain would get a number the rocket never reached. **Smoothing may not invent
/// altitude.** Monotone tangents keep the curve within the recorded values on every
/// interval: no overshoot, and any flat run stays exactly flat.
///
/// *Position* uses ordinary Catmull-Rom tangents. A ground track has no meaningful extremum
/// to preserve, and its overshoot is sub-metre on a curve of hundreds — well under the GPS
/// accuracy the points themselves carry — while monotone limiting there would flatten
/// genuine curvature in a turn.
///
/// Parameterised by point index, matching how the curtain walks intervals, so a caller with
/// a *time* fraction inside interval `i` can pass it straight in.
///
/// Ported from Android's `MapLibreCompat.PathSpline`.
struct PathSpline {
    private let path: [TrackPoint]
    private let n: Int
    private var mLat: [Double]
    private var mLon: [Double]
    private var mAlt: [Float]

    init(_ path: [TrackPoint]) {
        self.path = path
        self.n = path.count
        self.mLat = [Double](repeating: 0, count: max(n, 1))
        self.mLon = [Double](repeating: 0, count: max(n, 1))
        self.mAlt = [Float](repeating: 0, count: max(n, 1))
        guard n >= 2 else { return }
        mLat = Self.catmullRomTangents(n) { path[$0].latitude }
        mLon = Self.catmullRomTangents(n) { path[$0].longitude }
        mAlt = Self.monotoneTangents(path)
    }

    /// Centred differences, one-sided at the ends.
    private static func catmullRomTangents(_ n: Int, _ value: (Int) -> Double) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let prev = value(i == 0 ? 0 : i - 1)
            let next = value(i == n - 1 ? n - 1 : i + 1)
            // Halved for interior points (a span of two intervals), full at the ends where
            // the span is one.
            out[i] = (i == 0 || i == n - 1) ? next - prev : (next - prev) / 2
        }
        return out
    }

    /// Fritsch–Carlson: start from centred differences, then clamp so no interval can
    /// overshoot the values bracketing it.
    private static func monotoneTangents(_ path: [TrackPoint]) -> [Float] {
        let n = path.count
        var m = [Float](repeating: 0, count: n)
        var d = [Float](repeating: 0, count: n - 1)          // secant slopes
        for i in 0..<(n - 1) { d[i] = path[i + 1].altitudeM - path[i].altitudeM }

        for i in 0..<n {
            if i == 0 { m[i] = d[0] }
            else if i == n - 1 { m[i] = d[n - 2] }
            else { m[i] = (d[i - 1] + d[i]) / 2 }
        }
        for i in 0..<(n - 1) {
            if d[i] == 0 {
                // A flat interval must stay exactly flat — a rocket sitting on the ground
                // may not bulge upward between two identical readings.
                m[i] = 0
                m[i + 1] = 0
            } else {
                let a = m[i] / d[i]
                let b = m[i + 1] / d[i]
                // A negative ratio means the tangent points against the interval, so the
                // curve would leave the bracket immediately.
                if a < 0 { m[i] = 0 }
                if b < 0 { m[i + 1] = 0 }
                let s = a * a + b * b
                if s > 9 {
                    let tau = 3 / s.squareRoot()
                    m[i] = tau * a * d[i]
                    m[i + 1] = tau * b * d[i]
                }
            }
        }
        return m
    }

    /// Altitude at fraction `t` through interval `i`.
    func altitude(at i: Int, t: Double) -> Float {
        guard n >= 2 else { return path.first?.altitudeM ?? 0 }
        let tf = Float(t)
        let t2 = tf * tf
        let t3 = t2 * tf
        return (2 * t3 - 3 * t2 + 1) * path[i].altitudeM
            + (t3 - 2 * t2 + tf) * mAlt[i]
            + (-2 * t3 + 3 * t2) * path[i + 1].altitudeM
            + (t3 - t2) * mAlt[i + 1]
    }

    func latitude(at i: Int, t: Double) -> Double {
        hermite(path[i].latitude, mLat[i], path[i + 1].latitude, mLat[i + 1], t)
    }

    func longitude(at i: Int, t: Double) -> Double {
        hermite(path[i].longitude, mLon[i], path[i + 1].longitude, mLon[i + 1], t)
    }

    private func hermite(_ p0: Double, _ m0: Double, _ p1: Double, _ m1: Double,
                         _ t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p0
            + (t3 - 2 * t2 + t) * m0
            + (-2 * t3 + 3 * t2) * p1
            + (t3 - t2) * m1
    }
}
