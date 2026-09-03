import XCTest
@testable import SteamPigeon

/// The flight callouts, ported from Android's `FlightSpeechAnnouncer`.
///
/// Almost every rule here is a rule about **staying quiet** — over a rocket already on the
/// ground, over a position the app cannot stand behind, over a link that was never live.
/// Those are invisible when they work and impossible to exercise without a locator, which
/// is why the state machine was ported as something that can be driven from a test.
final class FlightAnnouncerTests: XCTestCase {

    private let pad = (lat: 47.0, lon: -122.0)
    /// ~1.1 km north of the pad.
    private let downrange = (lat: 47.01, lon: -122.0)

    private func sample(_ state: FlightStates,
                        aglM: Float = 0,
                        descentRateMs: Float = 0,
                        velocityMs: Float = 0,
                        gpsOk: Bool = true,
                        messageAge: TimeInterval = 0,
                        position: (lat: Double, lon: Double)? = nil,
                        drogueDetected: Bool = false,
                        mainDetected: Bool = false,
                        modes: [DeployMode] = [.droguePrimary, .drogueBackup, .mainPrimary, .mainBackup],
                        fired: [Bool] = [false, false, false, false]) -> FlightAnnouncer.Sample {
        FlightAnnouncer.Sample(inFlight: true, flightState: state, altitudeAglM: aglM,
                               descentRateMs: descentRateMs, velocityMs: velocityMs,
                               gpsOk: gpsOk, messageAge: messageAge, position: position,
                               drogueDeployDetected: drogueDetected,
                               mainDeployDetected: mainDetected,
                               channelModes: modes, channelFired: fired)
    }

    private func texts(_ lines: [FlightAnnouncer.Line]) -> [String] { lines.map(\.text) }

    // MARK: - Discrete events

    func testApogeeIsAnnouncedOnceWithItsAltitude() {
        var a = FlightAnnouncer()
        _ = a.flightStateChanged(sample(.launched, position: pad))
        XCTAssertEqual(["Apogee, 1234 meters."],
                       texts(a.flightStateChanged(sample(.noseover, aglM: 1234))))
        // The state cannot go backwards, and a repeat of the same state says nothing.
        XCTAssertEqual([], texts(a.flightStateChanged(sample(.noseover, aglM: 1234))))
    }

    /// The charge callouts are gated on a channel wired for that role having FIRED, not on
    /// the flight state alone: the state says the locator reached the event, the stats say
    /// something actually went off.
    func testAChargeIsAnnouncedOnlyWhenAChannelWiredForItFired() {
        var a = FlightAnnouncer()
        _ = a.flightStateChanged(sample(.launched, position: pad))
        // The apogee line rides along: reaching the drogue event means noseover was
        // passed. What is absent is the charge.
        XCTAssertEqual(["Apogee, 0 meters."],
                       texts(a.flightStateChanged(sample(.droguePrimaryEvent))),
                       "reached the event, nothing fired")

        var b = FlightAnnouncer()
        _ = b.flightStateChanged(sample(.launched, position: pad))
        let lines = b.flightStateChanged(sample(.droguePrimaryEvent,
                                                fired: [true, false, false, false]))
        XCTAssertEqual(["Apogee, 0 meters.", "Drogue charge."], texts(lines),
                       "a jump past noseover carries the apogee callout with it")
    }

    /// **Android tests channels 1 and 2 only**, while its own default wiring puts
    /// MainPrimary on channel 3 — so the stock configuration cannot produce a "Main charge."
    /// callout there. Ported as every channel; see `docs/UI_PARITY.md`.
    func testTheMainChargeOnChannelThreeIsAnnounced() {
        var a = FlightAnnouncer()
        _ = a.flightStateChanged(sample(.noseover, position: pad))
        let lines = a.flightStateChanged(sample(.mainPrimaryEvent,
                                                fired: [false, false, true, false]))
        XCTAssertTrue(texts(lines).contains("Main charge."))
    }

    // MARK: - The quiet rules

    /// A link that returns after the rocket is down delivers the whole flight in one step.
    /// Announcing the charges it flew through minutes ago is worse than saying nothing.
    func testALandedRocketSaysLandingAndNothingElse() {
        var a = FlightAnnouncer()
        _ = a.flightStateChanged(sample(.launched, position: pad))
        let lines = a.flightStateChanged(sample(.landed, position: downrange,
                                                fired: [true, true, true, true]))
        XCTAssertEqual(1, lines.count)
        XCTAssertTrue(lines[0].text.hasPrefix("Landing"), lines[0].text)
        XCTAssertEqual(.urgent, lines[0].priority)
    }

    /// Landing names where to walk, in metres and a compass point from the launch site.
    func testTheLandingCalloutCarriesTheWalkFromTheLaunchPoint() {
        var a = FlightAnnouncer()
        _ = a.flightStateChanged(sample(.launched, position: pad))
        let text = a.flightStateChanged(sample(.landed, position: downrange))[0].text
        XCTAssertTrue(text.contains("meters north of launch point."), text)
    }

    /// ADR-0022's ceiling applies to what is SPOKEN as well as what is shown: a distance
    /// read aloud is instruction rather than readout.
    func testAnImplausibleDistanceIsNotReadOutAsABearing() {
        var a = FlightAnnouncer()
        _ = a.flightStateChanged(sample(.launched, position: pad))
        let text = a.flightStateChanged(sample(.landed, position: (lat: 0, lon: 0)))[0].text
        XCTAssertEqual("Landing, location unknown.", text)
    }

    /// A locator with no GPS fix has no position to offer, whatever numbers it sends.
    func testWithoutAGpsFixTheLandingSaysSoRatherThanQuotingAPosition() {
        var a = FlightAnnouncer()
        _ = a.flightStateChanged(sample(.launched, position: pad))
        let text = a.flightStateChanged(sample(.landed, gpsOk: false, position: downrange))[0].text
        XCTAssertEqual("Landing, location unknown.", text)
    }

    // MARK: - The poll loop

    func testAscentCalloutsEveryHundredMetresWhileStillMoving() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        // Rounded DOWN to the band it has passed, not to the altitude reached: at 120 m
        // the news is that it went through 100.
        XCTAssertEqual(["100 meters."],
                       texts(a.poll(sample(.burnout, aglM: 120, velocityMs: 100))))
        XCTAssertEqual([], texts(a.poll(sample(.burnout, aglM: 150, velocityMs: 100))),
                       "same hundred")
        XCTAssertEqual(["200 meters."],
                       texts(a.poll(sample(.burnout, aglM: 205, velocityMs: 100))))
    }

    /// Near apogee the rocket is barely moving and the altitude creeps across a boundary;
    /// the callout would be a number without news. The band is still marked as passed, so
    /// it is not announced late either.
    func testAnAscentCalloutIsSkippedWhenTheRocketHasAllButStopped() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        XCTAssertEqual([], texts(a.poll(sample(.burnout, aglM: 300, velocityMs: 1))))
        XCTAssertEqual([], texts(a.poll(sample(.burnout, aglM: 305, velocityMs: 100))))
    }

    /// Starting the app out of range is silence, not a report of something that was never
    /// there. Only a link that has been live can be lost.
    func testALinkThatWasNeverLiveIsNeverReportedLost() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        XCTAssertEqual([], texts(a.poll(sample(.launched, messageAge: 30))))
    }

    func testLosingAndRegainingTheLinkIsOneSentenceEach() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        _ = a.poll(sample(.launched, aglM: 500, messageAge: 0))
        let lost = texts(a.poll(sample(.launched, aglM: 500, messageAge: 4, position: downrange)))
        XCTAssertEqual(1, lost.count)
        XCTAssertTrue(lost[0].hasPrefix("Telemetry lost."), lost[0])
        XCTAssertEqual([], texts(a.poll(sample(.launched, aglM: 500, messageAge: 4))),
                       "a dropout is one sentence, not a chant")
        XCTAssertEqual(["Telemetry restored."], texts(a.poll(sample(.launched, aglM: 500))))
    }

    /// GPS health is edge-triggered too, and the first reading arms the edge rather than
    /// announcing — arming into a bad state is what the map's banner is for.
    func testGpsHealthIsAnnouncedOnChangeOnly() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        XCTAssertEqual([], texts(a.poll(sample(.launched, gpsOk: false))))
        XCTAssertEqual(["GPS fix restored."], texts(a.poll(sample(.launched, gpsOk: true))))
        XCTAssertEqual(["GPS fix lost."], texts(a.poll(sample(.launched, gpsOk: false))))
    }

    /// With no messages arriving the locator's last-sent status is stale and says nothing
    /// about whether it has a fix now.
    func testGpsHealthIsNotJudgedWithoutALiveLink() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        _ = a.poll(sample(.launched, gpsOk: true))
        XCTAssertEqual([], texts(a.poll(sample(.launched, gpsOk: false, messageAge: 10)))
                          .filter { $0.hasPrefix("GPS") })
    }

    func testDescentWarningsAreSpacedAndStopAtLanding() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        let start = Date()
        let first = a.poll(sample(.droguePrimaryEvent, aglM: 2000, descentRateMs: 60), now: start)
        XCTAssertEqual(["Descent warning, 60 meters per second"], texts(first))
        XCTAssertEqual([], texts(a.poll(sample(.droguePrimaryEvent, aglM: 1800, descentRateMs: 60),
                                        now: start.addingTimeInterval(5))))
        XCTAssertEqual(1, a.poll(sample(.droguePrimaryEvent, aglM: 1500, descentRateMs: 60),
                                 now: start.addingTimeInterval(11)).count)
    }

    /// Exactly one landing, and nothing after it — the deploy bits arrive latched, so a
    /// packet after the fact would otherwise re-announce a deployment.
    func testLandingIsAnnouncedOnceAndSilencesWhatFollows() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        _ = a.flightStateChanged(sample(.launched, position: pad))
        let landing = a.poll(sample(.mainPrimaryEvent, aglM: 10, descentRateMs: 5,
                                    position: downrange, mainDetected: true))
        XCTAssertEqual(1, landing.count)
        XCTAssertTrue(landing[0].text.hasPrefix("Landing"), landing[0].text)
        XCTAssertEqual([], texts(a.poll(sample(.mainPrimaryEvent, aglM: 5, descentRateMs: 5,
                                               position: downrange, mainDetected: true))))
    }

    /// The one the field cares about: the link dies on the way down and never returns.
    func testALandingIsStillCalledWhenTheLinkDiesOnTheWayDown() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        _ = a.flightStateChanged(sample(.launched, position: pad))
        let lines = a.poll(sample(.mainPrimaryEvent, aglM: 300, descentRateMs: 5,
                                  messageAge: 61, position: downrange))
        XCTAssertEqual(1, lines.count)
        XCTAssertTrue(lines[0].text.hasPrefix("Landing. Last known"), lines[0].text)
    }

    /// A deployment detected while the rocket is airborne is announced once; the same
    /// latched bit at Landed is not, even though the landing reset has just cleared the
    /// guard that would otherwise have stopped it.
    func testADeploymentIsNotReAnnouncedAfterTheLandingReset() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        _ = a.flightStateChanged(sample(.launched, position: pad))
        XCTAssertEqual(["Main deployed."],
                       texts(a.poll(sample(.mainPrimaryEvent, aglM: 500, mainDetected: true))))
        _ = a.flightStateChanged(sample(.landed, position: downrange))
        XCTAssertEqual([], texts(a.poll(sample(.landed, aglM: 0, mainDetected: true))))
    }

    /// Nothing at all while the flight has not started — the announcer is only wired up
    /// during a flight, and says so itself as well.
    func testNothingIsSaidOutsideAFlight() {
        var a = FlightAnnouncer()
        a.pollingStarted()
        var idle = sample(.waitingLaunch)
        idle.inFlight = false
        XCTAssertEqual([], texts(a.poll(idle)))
        XCTAssertEqual([], texts(a.flightStateChanged(idle)))
    }
}
