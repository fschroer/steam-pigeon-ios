import Foundation

/// Where to draw the rocket marker under canopy while the locator's fix is lost
/// (locator ADR-0022 amendment 2026-11-08, issue #72). Port of Android's
/// `ui/WindCoast.kt`; `WindCoastTests` carries `WindCoastTest`'s vectors.
///
/// While the fix is lost the locator keeps re-sending the last good lat/lon, so the
/// map held the marker where the rocket *was*, while under canopy it went on
/// drifting. This carries the last fix forward at the wind: the mean north/east GPS
/// velocity of the fixed packets heard in the last 5 s of descent.
///
/// The result is drawn, never measured: distance, bearing, the AR marker and the
/// callouts stay on the last real fix, and ADR-0022's jump test stays anchored there.
struct WindCoast {
    /// A coasted marker: position, the ring to draw around it, and its age.
    struct Coasted: Equatable {
        let latitude: Double
        let longitude: Double
        let radiusM: Double
        let sinceFixMs: Int64
    }

    /// The wind is the mean of this much descent before the fix was lost.
    static let windowMs: Int64 = 5_000
    /// Fewer fixed packets than this in the window and the outage does not coast.
    static let minSamples = 2
    /// The point moves for at most this long; the corpus measures no further.
    static let maxCoastMs: Int64 = 30_000
    /// Ring growth past the last fix's h_acc. 4 m/s held 95–98 % of 9 replayed
    /// descents at every outage length from 2 to 30 s; 3 m/s held 79–93 %.
    static let growthMps = 4.0
    private static let earthRadiusM = 6_371_000.0

    /// Flight states 4–7: drogue deployment through main backup.
    static func isDescent(_ state: FlightStates) -> Bool {
        (4...7).contains(Int(state.rawValue))
    }

    private struct Velocity { let atMs: Int64; let north: Float; let east: Float }

    private var recent: [Velocity] = []
    private var fixLat = 0.0
    private var fixLon = 0.0
    private var fixHaccM = 0.0
    private var fixAtMs: Int64 = -1
    // Latched once per outage, at its first fixless descent packet. A nil wind after
    // latching means "this outage does not coast".
    private var latched = false
    private var windNorth: Double?
    private var windEast: Double?
    private var landedAtMs: Int64 = -1

    mutating func reset() { self = WindCoast() }

    /// Feed every TelemetryData packet. Returns the coasted marker, or nil when the
    /// map should draw the locator's own position (a live fix, no fix ever, no wind
    /// to coast on, or not under canopy).
    mutating func update(nowMs: Int64, hasFix: Bool, inDescent: Bool, landed: Bool,
                         latitude: Double, longitude: Double,
                         velNorthMps: Float, velEastMps: Float, haccM: Float) -> Coasted? {
        if hasFix {
            fixLat = latitude; fixLon = longitude
            fixHaccM = (haccM.isFinite && haccM >= 0) ? Double(haccM) : 0
            fixAtMs = nowMs
            latched = false; windNorth = nil; windEast = nil; landedAtMs = -1
            // Only descent velocity is wind: before deployment it is the rocket's
            // own apogee momentum.
            if inDescent, velNorthMps.isFinite, velEastMps.isFinite {
                recent.append(Velocity(atMs: nowMs, north: velNorthMps, east: velEastMps))
            }
            recent.removeAll { nowMs - $0.atMs > Self.windowMs }
            return nil
        }
        guard fixAtMs >= 0 else { return nil }

        if !latched {
            guard inDescent else { return nil }   // coasting starts only under canopy
            latched = true
            let w = recent.filter { fixAtMs - $0.atMs <= Self.windowMs }
            if w.count >= Self.minSamples {
                windNorth = w.reduce(0.0) { $0 + Double($1.north) } / Double(w.count)
                windEast = w.reduce(0.0) { $0 + Double($1.east) } / Double(w.count)
            }
        }
        guard let wn = windNorth, let we = windEast else { return nil }

        if landed && landedAtMs < 0 { landedAtMs = nowMs }
        // Landed: the rocket has stopped, so the point and the ring stop with it.
        let endMs = landedAtMs >= 0 ? landedAtMs : nowMs
        let sinceFixMs = max(endMs - fixAtMs, 0)
        let movingS = Double(min(sinceFixMs, Self.maxCoastMs)) / 1000
        let dLat = wn * movingS / Self.earthRadiusM * 180 / .pi
        let dLon = we * movingS / (Self.earthRadiusM * cos(fixLat * .pi / 180)) * 180 / .pi
        return Coasted(latitude: fixLat + dLat,
                       longitude: fixLon + dLon,
                       radiusM: fixHaccM + Self.growthMps * Double(sinceFixMs) / 1000,
                       sinceFixMs: sinceFixMs)
    }
}
