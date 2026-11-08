import XCTest
@testable import SteamPigeon

/// The canopy wind coast (locator ADR-0022 amendment 2026-11-08, #72). The same
/// vectors as Android's `WindCoastTest`.
final class WindCoastTests: XCTestCase {
    private let lat0 = 46.25
    private let lon0 = -119.10
    private var mPerDegLat: Double { 6_371_000.0 * .pi / 180 }
    private var mPerDegLon: Double { mPerDegLat * cos(lat0 * .pi / 180) }

    /// 1 Hz fixed packets drifting at (north, east) m/s, ending at t = (n−1) s.
    private func drift(_ c: inout WindCoast, _ n: Int, _ north: Float, _ east: Float,
                       descent: Bool = true) {
        for i in 0..<n {
            _ = c.update(nowMs: Int64(i) * 1000, hasFix: true, inDescent: descent, landed: false,
                         latitude: lat0 + Double(north) * Double(i) / mPerDegLat,
                         longitude: lon0 + Double(east) * Double(i) / mPerDegLon,
                         velNorthMps: north, velEastMps: east, haccM: 2)
        }
    }

    private func lost(_ c: inout WindCoast, _ atMs: Int64, descent: Bool = true,
                      landed: Bool = false) -> WindCoast.Coasted? {
        c.update(nowMs: atMs, hasFix: false, inDescent: descent, landed: landed,
                 latitude: 0, longitude: 0, velNorthMps: 0, velEastMps: 0, haccM: 99)
    }

    private func fix(_ c: inout WindCoast, _ atMs: Int64, _ north: Float, _ east: Float) {
        _ = c.update(nowMs: atMs, hasFix: true, inDescent: true, landed: false,
                     latitude: lat0, longitude: lon0, velNorthMps: north, velEastMps: east, haccM: 2)
    }

    func testALiveFixIsNeverCoasted() {
        var c = WindCoast()
        drift(&c, 6, 3, -4)
        XCTAssertNil(c.update(nowMs: 6_000, hasFix: true, inDescent: true, landed: false,
                              latitude: lat0, longitude: lon0, velNorthMps: 3, velEastMps: -4, haccM: 2))
    }

    func testCarriesTheLastFixForwardAtTheWind() throws {
        var c = WindCoast()
        drift(&c, 6, 3, -4)                                  // last fix at t = 5 s
        let k = try XCTUnwrap(lost(&c, 15_000))              // 10 s later
        let lastLat = lat0 + 3.0 * 5 / mPerDegLat
        let lastLon = lon0 - 4.0 * 5 / mPerDegLon
        XCTAssertEqual((k.latitude - lastLat) * mPerDegLat, 30.0, accuracy: 0.01)
        XCTAssertEqual((k.longitude - lastLon) * mPerDegLon, -40.0, accuracy: 0.01)
        XCTAssertEqual(k.radiusM, 2.0 + 4.0 * 10, accuracy: 1e-9)
        XCTAssertEqual(k.sinceFixMs, 10_000)
    }

    func testStopsMovingAt30sButTheRingKeepsGrowing() throws {
        var c = WindCoast()
        drift(&c, 6, 0, 5)
        let at30 = try XCTUnwrap(lost(&c, 35_000))
        let at60 = try XCTUnwrap(lost(&c, 65_000))
        XCTAssertEqual(at30.longitude, at60.longitude, accuracy: 1e-12)
        XCTAssertEqual(at60.radiusM, 2.0 + 4.0 * 60, accuracy: 1e-9)
    }

    func testLandedFreezesPointAndRing() throws {
        var c = WindCoast()
        drift(&c, 6, 0, 5)
        _ = lost(&c, 10_000)
        let atLanding = try XCTUnwrap(lost(&c, 12_000, descent: false, landed: true))
        let later = try XCTUnwrap(lost(&c, 40_000, descent: false, landed: true))
        XCTAssertEqual(atLanding, later)
        XCTAssertEqual(later.sinceFixMs, 7_000)
        XCTAssertEqual(later.radiusM, 2.0 + 4.0 * 7, accuracy: 1e-9)
    }

    func testNoCoastWithoutEnoughWind() {
        var c = WindCoast()
        drift(&c, 1, 3, 3)
        XCTAssertNil(lost(&c, 5_000))
    }

    func testWindOnlyFromTheLastFiveSeconds() {
        // Two old samples at another speed, then a 6 s silence: they no longer count.
        var d = WindCoast()
        fix(&d, 0, 0, 50)
        fix(&d, 1_000, 0, 50)
        fix(&d, 7_000, 0, 5)
        XCTAssertNil(lost(&d, 9_000))   // only one sample inside the window
    }

    func testAscentAndPreDeploymentVelocityIsNotWind() {
        var c = WindCoast()
        drift(&c, 6, 0, 80, descent: false)                 // Noseover momentum, not wind
        XCTAssertNil(lost(&c, 8_000, descent: false))
        XCTAssertNil(lost(&c, 9_000))                       // deployment during the outage
    }

    func testReacquiringReplacesTheCoast() {
        var c = WindCoast()
        drift(&c, 6, 0, 5)
        XCTAssertNotNil(lost(&c, 10_000))
        XCTAssertNil(c.update(nowMs: 11_000, hasFix: true, inDescent: true, landed: false,
                              latitude: lat0, longitude: lon0, velNorthMps: 0, velEastMps: 5, haccM: 2))
    }

    func testANewOutageLatchesAFreshWind() throws {
        var c = WindCoast()
        drift(&c, 6, 0, 5)
        XCTAssertNotNil(lost(&c, 8_000))
        for i in 9...14 { fix(&c, Int64(i) * 1000, 2, 0) }
        let k = try XCTUnwrap(lost(&c, 24_000))
        XCTAssertEqual((k.latitude - lat0) * mPerDegLat, 20.0, accuracy: 0.01)
        XCTAssertEqual((k.longitude - lon0) * mPerDegLon, 0.0, accuracy: 0.01)
    }

    func testDescentStatesAreFourToSeven() {
        let all: [FlightStates] = [.waitingLaunch, .launched, .burnout, .noseover,
                                   .droguePrimaryEvent, .drogueBackupEvent,
                                   .mainPrimaryEvent, .mainBackupEvent, .landed]
        XCTAssertEqual(all.filter(WindCoast.isDescent).map { Int($0.rawValue) }, [4, 5, 6, 7])
    }
}
