import XCTest
@testable import SteamPigeon

/// One-second markers on the 3D flight path.
///
/// These are read as a ruler — climb rate comes from the spacing between them — so the thing
/// under test is that a mark sits at the altitude the rocket actually had one second in, not
/// at the altitude of the nearest sample. The path is live radio telemetry with a variable
/// interval and dropped packets, so counting samples would drift; every test here is built
/// to fail if the implementation ever falls back to that.
///
/// Ported from Android's `SecondMarkersTest.kt`, case for case.
final class SecondMarkersTests: XCTestCase {

    private let lat = 47.6146
    private let lon = -122.5526
    private let metersPerDegLat = 111_320.0
    private let t0: Int64 = 1_700_000_000_000     // arbitrary wall-clock epoch

    /// A fix `tMs` after t0, `northM` metres north of the reference point.
    private func fix(_ tMs: Int64, _ northM: Double, _ altM: Float) -> TrackPoint {
        TrackPoint(latitude: lat + northM / metersPerDegLat, longitude: lon,
                   altitudeM: altM, timestampMs: t0 + tMs)
    }

    /// A fix whose timestamp is a placeholder, as restored from a 3-column row.
    private func legacyFix(_ tMs: Int64, _ northM: Double, _ altM: Float) -> TrackPoint {
        TrackPoint(latitude: lat + northM / metersPerDegLat, longitude: lon,
                   altitudeM: altM, timestampMs: tMs, timeSynthetic: true)
    }

    private func heights(_ quads: [ExtrudedQuad]) -> [Double] { quads.map { Double($0.heightM) } }

    /// A steady 20 Hz climb at `climbRate` m/s lasting `seconds`.
    private func climb(_ seconds: Int, _ climbRate: Float) -> [TrackPoint] {
        (0...(seconds * 20)).map { i in
            let t = Int64(i) * 50
            return fix(t, Double(i) * 0.5, climbRate * Float(t) / 1000)
        }
    }

    // MARK: - Placement in time

    func testOneMarkPerElapsedSecondExcludingTheStart() {
        // 5 s of flight yields marks at t=1..5. The t=0 mark is deliberately absent: the
        // rocket is on the pad and the post would have no height.
        XCTAssertEqual(5, FlightPathGeometry.secondMarkers(climb(5, 100)).count)
    }

    func testMarksLandOnTrueSecondsAtASteadyClimbRate() {
        // 100 m/s means the Nth mark must stand at exactly N × 100 m.
        let h = heights(FlightPathGeometry.secondMarkers(climb(5, 100)))
        for (i, height) in h.enumerated() {
            XCTAssertEqual(Double(i + 1) * 100, height, accuracy: 0.5,
                           "mark \(i + 1) off the true second")
        }
    }

    func testMarksInterpolateBetweenSamplesRatherThanSnappingToOne() {
        // Elapsed time runs from the first fix. Samples straddle the one-second boundary at
        // 0.4 s and 1.4 s, so none sits near it; snapping to the nearest would put the mark
        // at 1400 m.
        //
        // The exact height is the smoothed curve's value, not the chord's, so this asserts
        // the discriminating property — the mark sits well inside the bracketing samples —
        // rather than pinning a linear value the curve no longer takes.
        let path = [fix(0, 0, 0), fix(400, 4, 400), fix(1400, 14, 1400)]
        let h = heights(FlightPathGeometry.secondMarkers(path))
        XCTAssertEqual(1, h.count)
        XCTAssertTrue(h.first! > 700 && h.first! < 1300, "snapped to a sample: \(h.first!)")
    }

    func testADroppedPacketDoesNotShiftLaterMarks() {
        // The defining case for timestamps over sample counting: drop every fix in the
        // second second, and marks 2..5 must not slide.
        let full = climb(5, 100)
        let gapped = full.filter { !((1051...1949).contains($0.timestampMs - t0)) }
        XCTAssertLessThan(gapped.count, full.count, "gap not actually created")

        let h = heights(FlightPathGeometry.secondMarkers(gapped))
        XCTAssertEqual(5, h.count)
        for (i, height) in h.enumerated() {
            XCTAssertEqual(Double(i + 1) * 100, height, accuracy: 1.0,
                           "mark \(i + 1) drifted after the dropout")
        }
    }

    func testAnIrregularRadioIntervalStillYieldsEvenlySpacedMarks() {
        // Wildly uneven sample spacing over a linear 50 m/s climb: the marks are a function
        // of time, so they must still come out at 50 m intervals.
        let path = [fix(0, 0, 0), fix(120, 1, 6), fix(1830, 15, 91.5),
                    fix(1900, 16, 95), fix(3400, 30, 170)]
        let h = heights(FlightPathGeometry.secondMarkers(path))
        XCTAssertEqual(3, h.count)
        // Tolerance covers the smoothed curve's departure from the chord on deliberately
        // uneven samples; a broken time axis would miss by far more, since the sample
        // spacing here varies by 25x.
        XCTAssertEqual(50.0, h[0], accuracy: 5)
        XCTAssertEqual(100.0, h[1], accuracy: 5)
        XCTAssertEqual(150.0, h[2], accuracy: 5)
    }

    func testMarksFollowTheProfileBackDownThroughApogee() {
        let path = [fix(0, 0, 0), fix(2000, 20, 600), fix(4000, 60, 900), fix(6000, 110, 300)]
        let h = heights(FlightPathGeometry.secondMarkers(path))
        let peak = h.indices.max(by: { h[$0] < h[$1] })!
        XCTAssertGreaterThan(peak, 0, "peak at start")
        XCTAssertLessThan(peak, h.count - 1, "peak at end")
    }

    // MARK: - Degenerate input

    func testTooShortOrTooBriefAPathProducesNoMarks() {
        XCTAssertTrue(FlightPathGeometry.secondMarkers([]).isEmpty)
        XCTAssertTrue(FlightPathGeometry.secondMarkers([fix(0, 0, 100)]).isEmpty)
        // Under a second of recording: no boundary has been crossed yet.
        XCTAssertTrue(FlightPathGeometry.secondMarkers([fix(0, 0, 100), fix(800, 5, 200)]).isEmpty)
    }

    func testNonMonotonicTimestampsProduceNoMarks() {
        // A clock adjustment mid-recording leaves no time axis to mark up; the builder must
        // bail rather than emit marks at invented times.
        XCTAssertTrue(FlightPathGeometry.secondMarkers([fix(5000, 0, 100), fix(0, 50, 500)]).isEmpty)
    }

    func testGroundLevelSecondsAreSkipped() {
        // A path recorded on the pad must not stand up zero-height posts.
        XCTAssertTrue(FlightPathGeometry.secondMarkers([fix(0, 0, 0), fix(3000, 1, 0.1)]).isEmpty)
    }

    func testAStationaryDescentStillGetsItsMarks() {
        // Under canopy in still air the fix can repeat exactly. There is no direction of
        // travel to orient the post across, but the altitude is still worth marking, so a
        // fallback orientation must be used rather than the mark being dropped.
        let quads = FlightPathGeometry.secondMarkers([fix(0, 0, 300), fix(3000, 0, 150)])
        XCTAssertEqual(3, quads.count)
        for quad in quads {
            for c in quad.ring {
                XCTAssertTrue(c.latitude.isFinite, "NaN corner from a zero-length interval")
                XCTAssertTrue(c.longitude.isFinite, "NaN corner from a zero-length interval")
            }
        }
    }

    // MARK: - Restored (pre-timestamp) recordings

    func testAFullyRestoredPathGetsNoMarksButStillHasItsGeometry() {
        // The whole point of keeping legacy rows: the track is real and must survive, but
        // its timestamps are invented, so no post may be stood on them. The curtain ignores
        // time entirely and still draws the wall.
        let path = (0...40).map { legacyFix(Int64($0) * 200, Double($0) * 2, Float($0) * 10) }
        XCTAssertTrue(FlightPathGeometry.secondMarkers(path).isEmpty)
        XCTAssertFalse(FlightPathGeometry.altitudeCurtain(path).isEmpty,
                       "restored path must still draw a curtain")
    }

    func testARestoredPrefixDoesNotAnchorTheLivePortionsMarks() {
        // Reload a legacy path, then keep recording: placeholder times start near zero while
        // real ones are wall-clock, so anchoring elapsed time to the first point would put
        // every boundary billions of ms away and yield nothing. Marks must run from the
        // first REAL fix.
        let restored = (0...9).map { legacyFix(Int64($0) * 200, Double($0), 50) }
        let live = (0...3).map { fix(Int64($0) * 1000, 100 + Double($0), 200 + Float($0) * 100) }
        let h = heights(FlightPathGeometry.secondMarkers(restored + live))

        XCTAssertEqual(3, h.count)
        XCTAssertEqual(300.0, h[0], accuracy: 1)
        XCTAssertEqual(400.0, h[1], accuracy: 1)
        XCTAssertEqual(500.0, h[2], accuracy: 1)
    }

    func testTheIntervalStraddlingTheRestoredToLiveSeamIsSkipped() {
        // Where a placeholder time meets a real one there is no meaningful span to
        // interpolate across, so that interval must produce no mark even though a second
        // boundary falls inside it.
        let path = [legacyFix(0, 0, 100), legacyFix(200, 1, 200),
                    fix(0, 2, 300),                    // seam: real time restarts here
                    fix(2000, 3, 500)]
        let h = heights(FlightPathGeometry.secondMarkers(path))
        // The assertion that matters is the COUNT: only the fully-real interval contributes,
        // so two marks rather than three.
        XCTAssertEqual(2, h.count)
        XCTAssertEqual(400.0, h[0], accuracy: 10)
        XCTAssertEqual(500.0, h[1], accuracy: 10)
    }

    func testMarkCountIsCapped() {
        // An hour-long recording left running must not emit 3600 posts, all rebuilt on every
        // telemetry message.
        let path = [fix(0, 0, 500), fix(3_600_000, 5000, 500)]
        XCTAssertLessThanOrEqual(FlightPathGeometry.secondMarkers(path).count, 600)
    }

    // MARK: - Geometry

    func testPostsAreClosedRingsWiderThanTheCurtainTheyMark() {
        // The post must protrude from the 1.5 m-wide curtain on both faces, or the
        // coincident geometry z-fights instead of reading as a mark.
        let cosLat = cos(lat * .pi / 180)
        for quad in FlightPathGeometry.secondMarkers(climb(3, 100)) {
            XCTAssertEqual(5, quad.ring.count, "ring must have 5 points (closed quad)")
            XCTAssertEqual(quad.ring.first!.longitude, quad.ring.last!.longitude, accuracy: 1e-12)
            XCTAssertEqual(quad.ring.first!.latitude, quad.ring.last!.latitude, accuracy: 1e-12)

            // Corners 0 and 3 straddle the post across the track.
            let dx = (quad.ring[3].longitude - quad.ring[0].longitude) * metersPerDegLat * cosLat
            let dy = (quad.ring[3].latitude - quad.ring[0].latitude) * metersPerDegLat
            XCTAssertEqual(3.2, (dx * dx + dy * dy).squareRoot(), accuracy: 0.05, "post width")
        }
    }
}
