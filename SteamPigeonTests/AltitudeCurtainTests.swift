import XCTest
@testable import SteamPigeon

/// Geometry for the 3D flight-path altitude curtain.
///
/// The wall is built by offsetting perpendicular to each track segment. That offset has to
/// be computed in metres — longitude degrees shrink by cos(lat) — or the wall silently skews
/// and widens with latitude, which is invisible on a tilted 3D map until you measure it.
///
/// Ported from Android's `AltitudeCurtainTest.kt`, case for case.
final class AltitudeCurtainTests: XCTestCase {

    private let lat = 47.6146            // the test site — cos(lat) ≈ 0.674
    private let lon = -122.5526
    private let metersPerDegLat = 111_320.0
    private let targetRiserM: Float = 0.25          // curtainTargetRiserM
    private let maxSubdivisions = 512               // curtainMaxSubdivisions
    private let halfWidthM = 0.75                   // curtainHalfWidthM

    /// Offset `northM`/`eastM` metres from the reference point. Timestamps are irrelevant
    /// to the curtain.
    private func offset(_ northM: Double, _ eastM: Double, _ altM: Float,
                        timestampMs: Int64 = 0) -> TrackPoint {
        let dLat = northM / metersPerDegLat
        let dLon = eastM / (metersPerDegLat * cos(lat * .pi / 180))
        return TrackPoint(latitude: lat + dLat, longitude: lon + dLon,
                          altitudeM: altM, timestampMs: timestampMs)
    }

    private func heights(_ quads: [ExtrudedQuad]) -> [Double] { quads.map { Double($0.heightM) } }

    /// Ground distance in metres between two points near the test site.
    private func metersBetween(_ a: PathCoord, _ b: PathCoord) -> Double {
        let cosLat = cos(a.latitude * .pi / 180)
        let dx = (b.longitude - a.longitude) * metersPerDegLat * cosLat
        let dy = (b.latitude - a.latitude) * metersPerDegLat
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Degenerate input

    func testEmptyOrSinglePointProducesNoCurtain() {
        XCTAssertTrue(FlightPathGeometry.altitudeCurtain([]).isEmpty)
        XCTAssertTrue(FlightPathGeometry.altitudeCurtain([offset(0, 0, 100)]).isEmpty)
    }

    func testGroundLevelTrackProducesNoCurtain() {
        // A rocket still on the pad, or a path recorded at zero AGL, must not draw a
        // degenerate zero-height wall over the ground track.
        let path = [offset(0, 0, 0), offset(10, 0, 0), offset(20, 0, 0.1)]
        XCTAssertTrue(FlightPathGeometry.altitudeCurtain(path).isEmpty)
    }

    func testStationaryPointsAreSkipped() {
        // Repeated identical fixes (rocket landed, still transmitting) have no direction to
        // offset perpendicular to — they must not emit NaN geometry.
        let p = offset(0, 0, 50)
        XCTAssertTrue(FlightPathGeometry.altitudeCurtain([p, p, p]).isEmpty)
    }

    // MARK: - Subdivision

    func testSubdivisionIsBudgetedByAltitudeChangeNotSegmentCount() {
        // The whole point of the adaptive split: a steep interval must be cut finer than a
        // shallow one covering the same ground. A fixed count divides the ground run evenly
        // and gives both the same treatment, which is what left boost looking like stairs.
        let f = FlightPathGeometry.curtainSubdivisions
        XCTAssertEqual(1, f(100, 100, 1))
        XCTAssertEqual(1, f(100, 100.5, 1))
        XCTAssertEqual(10, f(100, 110, 1))
        XCTAssertEqual(10, f(110, 100, 1))              // descent is symmetric
        XCTAssertEqual(maxSubdivisions, f(0, 5000, 1))
        // A relaxed riser buys back proportionally fewer quads.
        XCTAssertEqual(5, f(100, 110, 2))
    }

    func testAnOrdinaryFlightGetsTheFullTargetRiser() {
        let hop = [offset(0, 0, 0), offset(50, 0, 100)]
        XCTAssertEqual(targetRiserM, FlightPathGeometry.curtainRiser(hop), accuracy: 1e-6)
    }

    func testSensorNoiseOnAHighRatePathDoesNotCoarsenTheRiser() {
        // The regression this guards is subtle and cost Android several rounds to find.
        //
        // The quad backstop is driven by SUMMED |altitude change|, which cannot distinguish
        // flight profile from sensor noise. Raw baro at the 20 Hz archive cadence jitters a
        // few metres per sample, so summing absolute differences over ~2000 samples reports
        // thousands of metres of "variation" for a flight that only climbed ~120 m. With a
        // low ceiling that inflated the riser from 0.25 m to several metres — coarsening the
        // wall precisely on the densest data, which is the opposite of intended.
        var seed: UInt64 = 7
        func rand() -> Double {                      // deterministic, like Android's Random(7)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let noisy = (0...2000).map { i -> TrackPoint in
            let t = Double(i) / 20
            let profile = t < 12 ? 122 * (t / 12) : 122 * max(1 - (t - 12) / 88, 0)
            return offset(Double(i) * 0.1, 0, Float(profile + (rand() - 0.5) * 6))
        }
        var summed: Float = 0
        for i in 0..<(noisy.count - 1) { summed += abs(noisy[i + 1].altitudeM - noisy[i].altitudeM) }
        XCTAssertGreaterThan(summed, 2000, "test data should be noise-dominated")
        XCTAssertEqual(targetRiserM, FlightPathGeometry.curtainRiser(noisy), accuracy: 1e-6,
                       "noise must not inflate the riser (summed variation was \(summed) m)")
    }

    func testAnExtremePathStillRelaxesRatherThanExploding() {
        // The backstop is deliberately high, not absent: something pathological must still
        // be bounded rather than emitting unbounded geometry.
        let absurd = [offset(0, 0, 0), offset(500, 0, 30_000), offset(1000, 0, 0)]
        XCTAssertGreaterThan(FlightPathGeometry.curtainRiser(absurd), targetRiserM,
                             "riser should relax on an absurd path")
        XCTAssertLessThanOrEqual(FlightPathGeometry.altitudeCurtain(absurd).count, 21_000,
                                 "quad count should stay bounded")
    }

    func testEveryRiserStaysUnderTheBudget() {
        // The invariant the smoothness actually depends on: no step in the wall's top edge
        // taller than the path's riser target, across a segment whose split is not capped.
        let h = heights(FlightPathGeometry.altitudeCurtain([offset(0, 0, 0), offset(20, 0, 40)]))
        for i in 0..<(h.count - 1) {
            // Tolerance is float-rounding slack, not budget slack.
            XCTAssertLessThanOrEqual(abs(h[i + 1] - h[i]), Double(targetRiserM) + 1e-3,
                                     "riser \(h[i + 1] - h[i]) exceeds budget")
        }
    }

    func testLevelFlightIsNotSubdividedAtAll() {
        // Sub-segments of a level interval would all carry the same height, so splitting it
        // buys nothing and just multiplies the feature count on a source rebuilt on every
        // telemetry message.
        let path = [offset(0, 0, 300), offset(100, 0, 300), offset(200, 0, 300)]
        XCTAssertEqual(2, FlightPathGeometry.altitudeCurtain(path).count)
    }

    func testHeightsRampAcrossTheSegmentRatherThanStepAtItsEnds() {
        // A single climbing segment: sub-segment heights must increase monotonically and
        // stay strictly inside the endpoint altitudes, since each is the mean of its own
        // sub-endpoints.
        let h = heights(FlightPathGeometry.altitudeCurtain([offset(0, 0, 0), offset(100, 0, 800)]))

        XCTAssertEqual(maxSubdivisions, h.count)      // 800 m of climb hits the cap
        for i in 0..<(h.count - 1) { XCTAssertGreaterThan(h[i + 1], h[i], "heights not increasing") }
        XCTAssertGreaterThan(h.first!, 0.0, "first step too low")
        XCTAssertLessThan(h.last!, 800.0, "last step exceeds apogee")
        // Mid-segment should sit near the midpoint altitude.
        XCTAssertEqual(400.0, h[h.count / 2 - 1] / 2 + h[h.count / 2] / 2, accuracy: 60)
    }

    func testDescentProducesDecreasingHeights() {
        let h = heights(FlightPathGeometry.altitudeCurtain([offset(0, 0, 500), offset(50, 50, 20)]))
        for i in 0..<(h.count - 1) { XCTAssertLessThan(h[i + 1], h[i], "heights not decreasing") }
    }

    // MARK: - Wall geometry

    func testWallWidthIsCorrectInMetersRegardlessOfHeading() {
        // Guards the half-width constant and the normalisation step. Note this does NOT
        // catch a missing cos(lat) correction: the normal is normalised to a fixed length
        // before being converted back to degrees, so its magnitude survives that bug and
        // only its direction skews — which is what the perpendicularity case covers.
        for (north, east) in [(100.0, 0.0), (0.0, 100.0), (70.0, 70.0)] {
            let path = [offset(0, 0, 100), offset(north, east, 100)]
            let ring = FlightPathGeometry.altitudeCurtain(path).first!.ring
            // Ring is [left0, left1, right1, right0, left0] — the first and fourth corners
            // straddle the segment start, two half-widths apart.
            XCTAssertEqual(halfWidthM * 2, metersBetween(ring[0], ring[3]), accuracy: 0.05,
                           "wall width wrong for heading N=\(north) E=\(east)")
        }
    }

    func testWallIsPerpendicularToItsSegment() {
        // The offset must be normal to the direction of travel, not an arbitrary diagonal —
        // otherwise the wall leans away from the track.
        let path = [offset(0, 0, 100), offset(100, 100, 100)]
        let ring = FlightPathGeometry.altitudeCurtain(path).first!.ring
        let cosLat = cos(lat * .pi / 180)

        let segX = (ring[1].longitude - ring[0].longitude) * metersPerDegLat * cosLat
        let segY = (ring[1].latitude - ring[0].latitude) * metersPerDegLat
        let widX = (ring[3].longitude - ring[0].longitude) * metersPerDegLat * cosLat
        let widY = (ring[3].latitude - ring[0].latitude) * metersPerDegLat

        let dot = segX * widX + segY * widY
        let norm = (segX * segX + segY * segY).squareRoot() * (widX * widX + widY * widY).squareRoot()
        XCTAssertLessThan(abs(dot / norm), 0.01, "wall not perpendicular")
    }

    func testPolygonRingsAreClosed() {
        let path = [offset(0, 0, 100), offset(100, 40, 300)]
        for quad in FlightPathGeometry.altitudeCurtain(path) {
            XCTAssertEqual(5, quad.ring.count, "ring must have 5 points (closed quad)")
            XCTAssertEqual(quad.ring.first!.longitude, quad.ring.last!.longitude, accuracy: 1e-12)
            XCTAssertEqual(quad.ring.first!.latitude, quad.ring.last!.latitude, accuracy: 1e-12)
        }
    }

    func testCurtainFollowsAFullFlightProfile() {
        // Boost, apogee, descent — heights must peak once, in the middle.
        let path = [offset(0, 0, 0), offset(20, 5, 250), offset(45, 12, 900),
                    offset(80, 30, 400), offset(110, 55, 5)]
        let h = heights(FlightPathGeometry.altitudeCurtain(path))
        XCTAssertFalse(h.isEmpty)
        let peakIndex = h.indices.max(by: { h[$0] < h[$1] })!
        XCTAssertGreaterThan(peakIndex, 0, "peak at start")
        XCTAssertLessThan(peakIndex, h.count - 1, "peak at end")
        XCTAssertGreaterThan(h[peakIndex], 800.0, "peak height not near apogee")
    }
}
