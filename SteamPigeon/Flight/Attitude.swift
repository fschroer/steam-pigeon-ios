import Foundation

extension Quaternionf {

    /// The body +x axis (the rocket's nose) rotated into NED — the first column of
    /// R(q). Everything below is a reading of this one vector.
    var noseNED: (north: Float, east: Float, down: Float) {
        (north: 1 - 2 * (y * y + z * z),
         east:  2 * (x * y + w * z),
         down:  2 * (x * z - w * y))
    }

    /// Angle from vertical, degrees. **0 is straight up, 90 is horizontal.**
    ///
    /// Clamped before `acos` because a quaternion that is fractionally un-normalised
    /// — which any integrated estimate will be — can push the component just past
    /// ±1, and `acos` of that is NaN. A NaN here does not fail loudly; it renders as
    /// "nan°" on the panel.
    var inclinationDeg: Double {
        let d = Double(noseNED.down)
        return acos(min(max(-d, -1), 1)) * 180 / .pi
    }

    /// Compass bearing of the nose projected onto the horizontal plane, 0–360°.
    var headingDeg: Double {
        let n = noseNED
        let h = atan2(Double(n.east), Double(n.north)) * 180 / .pi
        return h < 0 ? h + 360 : h
    }
}

extension Vec3f {
    /// Total speed from an NED velocity vector.
    var magnitude: Float { (x * x + y * y + z * z).squareRoot() }
}

/// Map scale, in MapLibre's zoom convention.
enum MapScale {
    /// Ground metres per POINT.
    ///
    /// **MapLibre's zoom runs ~1 level deeper than Google's** (512- vs 256-px tile
    /// convention), so any zoom or scale maths has to use MapLibre's — mixing the two
    /// is a silent factor-of-two.
    static func metersPerPoint(zoom: Double, latitude: Double) -> Double {
        78271.51696 * cos(latitude * .pi / 180) / pow(2, zoom)
    }

    /// Ground metres per DEVICE pixel — for comparing a real distance against a real
    /// number of screen pixels.
    static func metersPerDevicePixel(zoom: Double, latitude: Double, scale: Double) -> Double {
        metersPerPoint(zoom: zoom, latitude: latitude) / scale
    }

    /// A round number of metres that fits `maxWidthPoints`, and the width to draw it.
    ///
    /// Picks from a 1/2/5 sequence so the bar always reads as a number someone can
    /// use, rather than whatever the viewport happens to make exact.
    static func niceScale(maxWidthPoints: Double, metersPerPoint: Double) -> (meters: Double, widthPoints: Double)? {
        guard maxWidthPoints > 0, metersPerPoint > 0 else { return nil }
        let maxMeters = maxWidthPoints * metersPerPoint
        guard maxMeters > 0 else { return nil }

        let magnitude = pow(10, (log10(maxMeters)).rounded(.down))
        for step in [5.0, 2.0, 1.0] {
            let candidate = magnitude * step
            if candidate <= maxMeters {
                return (candidate, candidate / metersPerPoint)
            }
        }
        let fallback = magnitude / 2
        return (fallback, fallback / metersPerPoint)
    }
}
