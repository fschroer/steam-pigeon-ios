import XCTest
@testable import SteamPigeon

/// Smoothing of the 3D path's top edge.
///
/// The point of `PathSpline` is to round the corners straight-chord interpolation leaves at
/// every recorded point. The danger in doing that is inventing data: a plain Catmull-Rom
/// spline overshoots near a sharp extremum, and the sharpest feature in a flight profile is
/// apogee — so it would draw the rocket above the altitude it actually reached, and anyone
/// reading apogee off the curtain would get a number no sensor ever produced.
///
/// Hence monotone (Fritsch–Carlson) tangents on altitude. Most of this file exists to hold
/// that line: **smoothing may make the curve prettier, never higher.**
///
/// Ported from Android's `PathSplineTest.kt`, case for case.
final class PathSplineTests: XCTestCase {

    private let lat = 47.6146
    private let lon = -122.5526

    private func p(_ northM: Double, _ altM: Float) -> TrackPoint {
        TrackPoint(latitude: lat + northM / 111_320.0, longitude: lon,
                   altitudeM: altM, timestampMs: 0)
    }

    /// Samples the curve densely across every interval.
    private func sweep(_ path: [TrackPoint], steps: Int = 50) -> [Float] {
        let s = PathSpline(path)
        var out: [Float] = []
        for i in 0..<(path.count - 1) {
            for k in 0...steps { out.append(s.altitude(at: i, t: Double(k) / Double(steps))) }
        }
        return out
    }

    // MARK: - The line that must not be crossed

    func testTheCurveNeverRisesAboveTheRecordedApogee() {
        // A sharp apogee is exactly where an unconstrained spline overshoots.
        let path = [p(0, 0), p(20, 250), p(45, 900), p(80, 400), p(110, 5)]
        let peak = path.map(\.altitudeM).max()!
        let highest = sweep(path).max()!
        XCTAssertLessThanOrEqual(highest, peak + 1e-3,
            "curve reached \(highest) above recorded apogee \(peak) — smoothing invented altitude")
    }

    func testTheCurveNeverDipsBelowTheRecordedMinimum() {
        // The mirror case: undershoot at a sharp trough would put the rocket underground,
        // which the curtain would render as a wall below the terrain.
        let path = [p(0, 500), p(20, 100), p(40, 2), p(60, 90), p(80, 480)]
        let floor = path.map(\.altitudeM).min()!
        let lowest = sweep(path).min()!
        XCTAssertGreaterThanOrEqual(lowest, floor - 1e-3,
            "curve dipped to \(lowest) below recorded minimum \(floor)")
    }

    func testEveryIntervalStaysWithinItsOwnEndpoints() {
        // Stronger than a global bound: a monotone run must not bulge locally either, or a
        // steady climb grows bumps that were never flown.
        let path = [p(0, 0), p(10, 5), p(20, 300), p(30, 320), p(40, 700)]
        let s = PathSpline(path)
        for i in 0..<(path.count - 1) {
            let lo = min(path[i].altitudeM, path[i + 1].altitudeM)
            let hi = max(path[i].altitudeM, path[i + 1].altitudeM)
            for k in 0...50 {
                let v = s.altitude(at: i, t: Double(k) / 50)
                XCTAssertTrue(v >= lo - 1e-3 && v <= hi + 1e-3,
                              "interval \(i) left [\(lo),\(hi)] at \(v)")
            }
        }
    }

    func testAFlatRunStaysExactlyFlat() {
        // A rocket sitting on the ground must not bulge upward between two identical
        // readings — this is the d == 0 branch of the tangent limiter.
        let path = [p(0, 100), p(10, 100), p(20, 100), p(30, 140)]
        let s = PathSpline(path)
        for k in 0...50 {
            XCTAssertEqual(100, s.altitude(at: 0, t: Double(k) / 50), accuracy: 1e-4)
            XCTAssertEqual(100, s.altitude(at: 1, t: Double(k) / 50), accuracy: 1e-4)
        }
    }

    // MARK: - That it actually smooths

    func testTheCurvePassesThroughEveryRecordedPoint() {
        // Smoothing must not drift off the data it is smoothing.
        let path = [p(0, 0), p(20, 250), p(45, 900), p(80, 400)]
        let s = PathSpline(path)
        for i in 0..<(path.count - 1) {
            XCTAssertEqual(path[i].altitudeM, s.altitude(at: i, t: 0), accuracy: 1e-4,
                           "start of interval \(i)")
            XCTAssertEqual(path[i + 1].altitudeM, s.altitude(at: i, t: 1), accuracy: 1e-4,
                           "end of interval \(i)")
        }
    }

    func testCollinearPointsReproduceTheStraightLine() {
        // Where the data is already straight there is nothing to smooth, and the curve must
        // not introduce waviness of its own.
        let path = (0...5).map { p(Double($0) * 10, Float($0) * 100) }
        let s = PathSpline(path)
        for i in 0..<(path.count - 1) {
            for k in 0...20 {
                let t = Double(k) / 20
                let linear = path[i].altitudeM
                    + (path[i + 1].altitudeM - path[i].altitudeM) * Float(t)
                XCTAssertEqual(linear, s.altitude(at: i, t: t), accuracy: 1e-3,
                               "interval \(i) at t=\(t)")
            }
        }
    }

    func testTheSlopeIsContinuousAcrossARecordedPoint() {
        // This is the actual visual complaint: straight chords meet at a corner on every
        // point. Slope entering a point must match slope leaving it.
        let path = [p(0, 0), p(20, 300), p(45, 700), p(80, 850)]
        let s = PathSpline(path)
        // 1e-3 rather than smaller: altitudes are Float, and a tighter step loses the
        // difference in rounding noise rather than measuring the slope.
        let h = 1e-3
        for i in 1..<(path.count - 1) {
            let incoming = Double(s.altitude(at: i - 1, t: 1.0) - s.altitude(at: i - 1, t: 1.0 - h)) / h
            let outgoing = Double(s.altitude(at: i, t: h) - s.altitude(at: i, t: 0.0)) / h
            // Relative, because a straight-chord path fails this by a FACTOR — at point 2
            // the old chords met at 400 vs 150 m per interval, a 2.7x jump — while a
            // continuous tangent differs only by rounding.
            let rel = abs(incoming - outgoing) / max(abs(incoming), abs(outgoing))
            XCTAssertLessThan(rel, 0.02,
                "corner at point \(i): slope \(incoming) -> \(outgoing)")
        }
    }

    func testTheGroundTrackIsSmoothedToo() {
        // The curtain's footprint follows the same curve; a polygonal ground track under a
        // smoothed top would still read as faceted.
        let path = [p(0, 100), p(20, 300), p(45, 500)]
        let s = PathSpline(path)
        for i in 0..<(path.count - 1) {
            XCTAssertEqual(path[i].latitude, s.latitude(at: i, t: 0), accuracy: 1e-12)
            XCTAssertEqual(path[i + 1].latitude, s.latitude(at: i, t: 1), accuracy: 1e-12)
        }
    }

    // MARK: - Degenerate input

    func testTwoPointsBehaveLinearly() {
        // With only two points there is no curvature information to use, and the curve must
        // not manufacture any.
        let path = [p(0, 0), p(100, 800)]
        let s = PathSpline(path)
        for k in 0...20 {
            let t = Double(k) / 20
            XCTAssertEqual(800 * Float(t), s.altitude(at: 0, t: t), accuracy: 1e-2)
        }
    }

    func testASmoothedCurtainStillDrawsAndStaysUnderApogee() {
        // End to end through the real builder: the emitted quad heights are what a reader
        // measures apogee from.
        let path = [p(0, 0), p(20, 250), p(45, 900), p(80, 400), p(110, 5)]
        let heights = FlightPathGeometry.altitudeCurtain(path).map(\.heightM)
        XCTAssertFalse(heights.isEmpty)
        XCTAssertLessThanOrEqual(heights.max()!, 900 + 1e-3,
                                 "curtain drew \(heights.max()!) above apogee 900")
    }
}
