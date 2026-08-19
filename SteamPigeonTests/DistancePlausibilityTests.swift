import XCTest
@testable import SteamPigeon

/// ADR-0022 invariants. These encode a callout of ~12 million metres that reached a
/// user: a launch point captured with no GPS lock at 0,0, read out as the
/// great-circle distance to null island.
final class DistancePlausibilityTests: XCTestCase {

    // MARK: - Geometry

    /// A degree of latitude is ~111 km anywhere; a cheap check that the haversine is
    /// not out by a unit or a radian conversion.
    func testOneDegreeOfLatitudeIsAboutOneHundredElevenKm() {
        let v = LocatorVector.between(from: (47.0, -122.0), to: (48.0, -122.0))
        XCTAssertEqual(111_195, v.distanceM, accuracy: 500)
        XCTAssertEqual(0, v.azimuthDeg, accuracy: 0.5, "due north")
    }

    func testBearingsPointTheRightWay() {
        XCTAssertEqual("north", LocatorVector.between(from: (47, -122), to: (48, -122)).ordinal)
        XCTAssertEqual("south", LocatorVector.between(from: (47, -122), to: (46, -122)).ordinal)
        XCTAssertEqual("east",  LocatorVector.between(from: (47, -122), to: (47, -121)).ordinal)
        XCTAssertEqual("west",  LocatorVector.between(from: (47, -122), to: (47, -123)).ordinal)
    }

    /// The failure that started the ADR: a launch point at 0,0 against a real
    /// position is roughly a third of the way around the planet.
    func testNullIslandProducesTheAbsurdDistanceTheAdrDescribes() {
        let v = LocatorVector.between(from: (0, 0), to: (47.6, -122.3))
        XCTAssertGreaterThan(v.distanceM, 10_000_000, "the ~12 million metre callout")
    }

    /// Distance is ground track only — no altitude term. That is what makes the
    /// speed bounds ground-speed bounds.
    func testDistanceIgnoresAltitude() {
        let a = LocatorVector.between(from: (47, -122), to: (47.001, -122), altitudeAglM: 0)
        let b = LocatorVector.between(from: (47, -122), to: (47.001, -122), altitudeAglM: 3000)
        XCTAssertEqual(a.distanceM, b.distanceM)
        XCTAssertGreaterThan(b.elevationDeg, a.elevationDeg, "but elevation does move")
    }

    // MARK: - Phase bounds (ADR-0022 Decision 3)

    func testSpeedBoundsMatchTheAdrTable() {
        XCTAssertEqual(400, DistancePlausibility.maxGroundSpeedMs(.launched))
        XCTAssertEqual(400, DistancePlausibility.maxGroundSpeedMs(.burnout))
        XCTAssertEqual(200, DistancePlausibility.maxGroundSpeedMs(.noseover))
        XCTAssertEqual(200, DistancePlausibility.maxGroundSpeedMs(.mainBackupEvent))
        XCTAssertEqual(5,   DistancePlausibility.maxGroundSpeedMs(.waitingLaunch))
        XCTAssertEqual(5,   DistancePlausibility.maxGroundSpeedMs(.landed))
    }

    /// An unrecognized state decodes to noSignal, and must be permissive — never
    /// blank a distance on the strength of a state we failed to parse.
    func testUnknownPhaseIsPermissive() {
        XCTAssertEqual(400, DistancePlausibility.maxGroundSpeedMs(.noSignal))
        XCTAssertEqual(400, DistancePlausibility.maxGroundSpeedMs(FlightStates.from(200)))
    }

    // MARK: - Decision 1: the range ceiling

    func testDistanceBeyondRadioRangeIsRejectedEvenWithAGoodFix() {
        var p = DistancePlausibility()
        XCTAssertNil(p.accept(distanceM: 12_000_000, hasFix: true, state: .waitingLaunch),
                     "a good fix does not license an impossible distance")
    }

    func testDistanceAtTheCeilingIsStillAccepted() {
        var p = DistancePlausibility()
        XCTAssertEqual(100_000, p.accept(distanceM: 100_000, hasFix: true, state: .landed))
    }

    func testNegativeDistanceIsRejected() {
        var p = DistancePlausibility()
        XCTAssertNil(p.accept(distanceM: -1, hasFix: true, state: .landed))
    }

    // MARK: - Decision 2: fixless is judged on jumping, not on being fixless

    /// The rule honoured, not excepted: a stale believable distance is still shown.
    func testFixlessButBelievableDistanceIsStillShown() {
        var p = DistancePlausibility()
        let t = Date()
        XCTAssertEqual(500, p.accept(distanceM: 500, hasFix: true, state: .landed, now: t))
        XCTAssertEqual(520, p.accept(distanceM: 520, hasFix: false, state: .landed,
                                     now: t.addingTimeInterval(1)),
                       "20 m with 100 m of noise margin is not a jump")
    }

    /// On the ground, 30 s without a fix licenses ~150 m, not ~12 km.
    func testGroundedRocketCannotJumpKilometres() {
        var p = DistancePlausibility()
        let t = Date()
        _ = p.accept(distanceM: 500, hasFix: true, state: .landed, now: t)
        XCTAssertNil(p.accept(distanceM: 12_000, hasFix: false, state: .landed,
                              now: t.addingTimeInterval(30)))
    }

    func testGroundedRocketMayDriftWithinWalkingPace() {
        var p = DistancePlausibility()
        let t = Date()
        _ = p.accept(distanceM: 500, hasFix: true, state: .landed, now: t)
        // 30 s x 5 m/s = 150 m budget, plus 100 m noise margin.
        XCTAssertEqual(700, p.accept(distanceM: 700, hasFix: false, state: .landed,
                                     now: t.addingTimeInterval(30)))
    }

    // MARK: - Decision 4: the allowance is integrated, not measured from the anchor

    /// A fixless stretch that spans phases must be charged phase by phase. Losing the
    /// fix under canopy and being heard from next on the ground is the normal way a
    /// descent ends — 2 km of real flight must not read as a jump.
    func testBudgetAccumulatesAcrossPhases() {
        var p = DistancePlausibility()
        let t = Date()
        _ = p.accept(distanceM: 100, hasFix: true, state: .noseover, now: t)

        // 20 s of descent at 200 m/s = 4 km of budget, accumulated in steps.
        var now = t
        for _ in 0..<20 {
            now = now.addingTimeInterval(1)
            _ = p.accept(distanceM: 100, hasFix: false, state: .noseover, now: now)
        }
        // Then it turns up on the ground 2 km away — real flight, not a jump.
        XCTAssertEqual(2_100, p.accept(distanceM: 2_100, hasFix: false, state: .landed,
                                       now: now.addingTimeInterval(1)))
    }

    /// The same 2 km, charged entirely at the ground bound, must be rejected — that
    /// is the difference integration makes.
    func testSameJumpIsRejectedWhenItWasNeverAirborne() {
        var p = DistancePlausibility()
        let t = Date()
        _ = p.accept(distanceM: 100, hasFix: true, state: .landed, now: t)
        var now = t
        for _ in 0..<21 {
            now = now.addingTimeInterval(1)
            _ = p.accept(distanceM: 100, hasFix: false, state: .landed, now: now)
        }
        XCTAssertNil(p.accept(distanceM: 2_100, hasFix: false, state: .landed, now: now))
    }

    /// A real fix resets the budget, so trust does not accumulate indefinitely.
    func testRealFixResetsTheBudget() {
        var p = DistancePlausibility()
        let t = Date()
        _ = p.accept(distanceM: 100, hasFix: true, state: .noseover, now: t)
        _ = p.accept(distanceM: 100, hasFix: false, state: .noseover, now: t.addingTimeInterval(20))
        _ = p.accept(distanceM: 150, hasFix: true, state: .landed, now: t.addingTimeInterval(21))
        // Budget is now zero; a 2 km jump on the ground is not allowed.
        XCTAssertNil(p.accept(distanceM: 2_150, hasFix: false, state: .landed,
                              now: t.addingTimeInterval(22)))
    }

    // MARK: - Fix definition

    func testFixNeedsFourSatellitesAndHealthyGps() {
        XCTAssertTrue(DistancePlausibility.hasFix(satellites: 4, gpsStatus: .ok))
        XCTAssertFalse(DistancePlausibility.hasFix(satellites: 3, gpsStatus: .ok))
        XCTAssertFalse(DistancePlausibility.hasFix(satellites: 9, gpsStatus: .warning))
        XCTAssertFalse(DistancePlausibility.hasFix(satellites: 9, gpsStatus: .stale))
    }

    /// With no fix ever recorded there is nothing to compare against, so only the
    /// range ceiling applies — and it is what stops null island.
    func testWithNoAnchorOnlyTheRangeCeilingApplies() {
        var p = DistancePlausibility()
        XCTAssertEqual(800, p.accept(distanceM: 800, hasFix: false, state: .waitingLaunch))
        var q = DistancePlausibility()
        XCTAssertNil(q.accept(distanceM: 12_000_000, hasFix: false, state: .waitingLaunch))
    }
}
