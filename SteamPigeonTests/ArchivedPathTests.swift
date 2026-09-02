import XCTest
@testable import SteamPigeon

/// A downloaded archive record, turned into a map path.
///
/// The archive stores position in radians and the live path is in degrees, so the
/// conversion is the whole feature: get it wrong and a Seattle-area flight is plotted in
/// the Atlantic with nothing raising an error.
///
/// Ported from Android's `ArchivedPathTest.kt`, case for case.
final class ArchivedPathTests: XCTestCase {

    // The test site, in the radians the archive actually stores.
    private let latDeg = 47.6146
    private let lonDeg = -122.5526
    private var latRad: Double { latDeg * .pi / 180 }
    private var lonRad: Double { lonDeg * .pi / 180 }

    private func sample(latRad: Double? = nil, lonRad: Double? = nil,
                        altM: Float = 100, tMs: Int = 0) -> FlightSample {
        FlightSample(timestampMs: tMs,
                     altitudeM: altM,
                     accel: Vec3f(x: 0, y: 0, z: 0),
                     gyro: Vec3f(x: 0, y: 0, z: 0),
                     latRad: latRad ?? self.latRad,
                     lonRad: lonRad ?? self.lonRad)
    }

    private func points(_ s: [FlightSample]) -> [TrackPoint] {
        FlightPathGeometry.archivedPathPoints(s)
    }

    // MARK: - Units

    func testRadiansAreConvertedToDegrees() {
        // The whole feature rests on this. Treating the stored radians as degrees would put
        // this flight at 0.83°N 2.14°W — in the Atlantic, ~5000 km off, with no error
        // raised anywhere.
        let p = points([sample()])
        XCTAssertEqual(1, p.count)
        XCTAssertEqual(latDeg, p[0].latitude, accuracy: 1e-9)
        XCTAssertEqual(lonDeg, p[0].longitude, accuracy: 1e-9)
    }

    func testASouthernAndEasternSiteKeepsItsSigns() {
        // Guards against an abs() or a swapped lat/lon creeping in.
        let lat = -33.8688, lon = 151.2093
        let p = points([sample(latRad: lat * .pi / 180, lonRad: lon * .pi / 180)])
        XCTAssertEqual(1, p.count)
        XCTAssertEqual(lat, p[0].latitude, accuracy: 1e-9)
        XCTAssertEqual(lon, p[0].longitude, accuracy: 1e-9)
    }

    // MARK: - Unusable positions

    func testSamplesWithoutAFixAreDropped() {
        // A record starts before GPS necessarily has a lock. A zero coordinate is not a
        // position on the Gulf of Guinea — it is "no fix" — and plotting it would run the
        // path to null island and wreck the map's bounds.
        let p = points([sample(latRad: 0, lonRad: 0, altM: 0),
                        sample(altM: 50),
                        sample(latRad: 0, lonRad: 0, altM: 80)])
        XCTAssertEqual(1, p.count)
        XCTAssertEqual(50, p[0].altitudeM)
    }

    func testNonFiniteAndOutOfRangeCoordinatesAreDropped() {
        let p = points([sample(latRad: .nan),
                        sample(lonRad: .infinity),
                        sample(latRad: 100 * .pi / 180 * 2),   // > 90° after conversion
                        sample(altM: 42)])                     // the only good one
        XCTAssertEqual(1, p.count)
        XCTAssertEqual(42, p[0].altitudeM)
    }

    func testAnEmptyRecordProducesAnEmptyPath() {
        XCTAssertTrue(points([]).isEmpty)
    }

    // MARK: - Time axis

    func testArchiveTimestampsCarryThroughAsRealTime() {
        // The archive clock is GPS-disciplined and counts from the record start, so an
        // archived path's markers mean what they say. These points must NOT be flagged
        // synthetic — that flag is for restored pre-timestamp paths.
        let p = points((0...40).map { sample(altM: Float($0) * 10, tMs: $0 * 50) })
        XCTAssertEqual(41, p.count)
        XCTAssertFalse(p.contains { $0.timeSynthetic },
                       "archive times must not be flagged synthetic")
        XCTAssertEqual(0, p.first!.timestampMs)
        XCTAssertEqual(2000, p.last!.timestampMs)
    }

    func testATwentyHertzRecordMarksEverySecondOfFlightTime() {
        // End to end at the real archive cadence: 5 s of samples, one marker per elapsed
        // second (t=0 excluded), each at the altitude of that second.
        let samples = (0...100).map { i in
            sample(latRad: latRad + Double(i) * 1e-7, altM: Float(i) * 5, tMs: i * 50)
        }
        let heights = FlightPathGeometry.secondMarkers(points(samples)).map { Double($0.heightM) }
        XCTAssertEqual(5, heights.count)
        for (i, h) in heights.enumerated() {
            XCTAssertEqual(Double(i + 1) * 100, h, accuracy: 1.0, "second \(i + 1)")
        }
    }

    func testDroppedLeadingSamplesDoNotShiftTheTimeAxis() {
        // Pre-fix samples are removed, so the path begins at the first sample that had a
        // position. Elapsed time must run from there — not from the record start — or every
        // marker sits a fixed offset early.
        let samples = (0...60).map { i in
            sample(latRad: i < 20 ? 0 : latRad,        // no fix for the first 20
                   lonRad: i < 20 ? 0 : lonRad,
                   altM: Float(i) * 5, tMs: i * 50)
        }
        let p = points(samples)
        XCTAssertEqual(41, p.count)
        XCTAssertEqual(1000, p.first!.timestampMs, "path must start at the first fixed sample")

        // Path spans t=1000..3000 ms, so marks land at 2000 and 3000 ms — 200 m and 300 m.
        let heights = FlightPathGeometry.secondMarkers(p).map { Double($0.heightM) }
        XCTAssertEqual(2, heights.count)
        XCTAssertEqual(200.0, heights[0], accuracy: 1.0)
        XCTAssertEqual(300.0, heights[1], accuracy: 1.0)
    }
}
