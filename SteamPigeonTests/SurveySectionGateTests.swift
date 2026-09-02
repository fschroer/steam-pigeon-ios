import XCTest
@testable import SteamPigeon

/// When the "Find a clean channel" section is on screen — and, since 2026-09-02, when its
/// **Stop** button is reachable, because the button lives inside it.
///
/// This gate has been wrong once and was documented as a hazard twice, so it is pinned
/// here rather than left as a comment. The failure it guards is specific: a sweep leaves
/// the receiver deaf for ~7.8 s, which is **longer** than the 5 s silence window
/// `hearingLocator` is judged on, so a gate on that term alone removes the section about
/// five seconds into its own scan — leaving it absent for the last ~3 s of every sweep,
/// which is exactly the stretch someone reaching for Stop is in.
@MainActor
final class SurveySectionGateTests: XCTestCase {

    private func offered(hearing: Bool, running: Bool, result: Bool) -> Bool {
        ChannelSurveySection.isOffered(hearingLocator: hearing,
                                       surveyInProgress: running,
                                       hasResult: result)
    }

    // MARK: - The rule ADR-0019/0029 actually states

    /// Offered while a locator is being heard: the sweep is for a link that works badly,
    /// and with nothing coming through the question is where the rocket is, not which
    /// channel is quiet.
    func testOfferedWhileALocatorIsHeard() {
        XCTAssertTrue(offered(hearing: true, running: false, result: false))
    }

    /// Not offered from a cold no-locator state — the narrowing ADR-0029 records.
    func testNotOfferedWithNothingHeardAndNothingRunning() {
        XCTAssertFalse(offered(hearing: false, running: false, result: false))
    }

    // MARK: - ...and not applied to a sweep already under way

    /// **The regression this file exists for.** Mid-sweep the receiver is deaf, so
    /// `hearingLocator` is false — and the section, with the Stop button in it, must stay.
    func testTheSectionSurvivesTheSweepsOwnDeafness() {
        XCTAssertTrue(offered(hearing: false, running: true, result: false),
                      "gone here is the Stop button gone for the last ~3 s of the sweep")
    }

    /// The instant the results land the sweep has ended, so `surveyInProgress` is false
    /// while the locator's next broadcast is still up to a second away. Without the result
    /// term the section hides and flickers back.
    func testTheSectionSurvivesTheGapBetweenResultsAndTheNextBroadcast() {
        XCTAssertTrue(offered(hearing: false, running: false, result: true))
    }

    /// Any one term is sufficient — the gate is a disjunction, and each term covers a
    /// stretch the others do not.
    func testEachTermAloneKeepsTheSectionOnScreen() {
        for (hearing, running, result) in [(true, false, false),
                                           (false, true, false),
                                           (false, false, true)] {
            XCTAssertTrue(offered(hearing: hearing, running: running, result: result),
                          "hearing=\(hearing) running=\(running) result=\(result)")
        }
    }

    // MARK: - The whole sweep, end to end

    /// Walks a sweep the way the clock does: heard, then deaf for ~7.8 s, then results,
    /// then broadcasts resume. The section must never leave the screen.
    ///
    /// `surveyInProgress` is what carries it across the deaf stretch, and it is only
    /// cleared by the response, the cancel, or the 15 s timeout — all of which outlast the
    /// sweep. That is why the button is reachable throughout.
    func testTheSectionIsContinuouslyOnScreenAcrossAWholeSweep() {
        // (label, hearingLocator, surveyInProgress, hasResult)
        let timeline: [(String, Bool, Bool, Bool)] = [
            ("t=0.0s  scan tapped, locator still audible", true,  true,  false),
            ("t=5.1s  silence window expires mid-sweep",   false, true,  false),
            ("t=7.8s  sweep ends, results land",           false, false, true),
            ("t=8.5s  broadcasts resume",                  true,  false, true),
        ]
        for (label, hearing, running, result) in timeline {
            XCTAssertTrue(offered(hearing: hearing, running: running, result: result), label)
        }
    }
}
