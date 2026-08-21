import XCTest
@testable import SteamPigeon

/// Ranking the receiver's band sweep (ADR-0019 tier 3), ported from Android's
/// `ChannelSurveyTest`.
///
/// The rules under test are not guessable from the data, and getting one wrong produces
/// confident bad advice rather than an error: recommend a channel the locators are
/// already on, or tell someone to change channel when the real fix is to move the
/// transmitter sitting next to the receiver.
final class ChannelSurveyTests: XCTestCase {

    /// A quiet band with one loud channel.
    private func quietBand(hot: Int, hotLevel: Int = -55, floor: Int = -110) -> [Int] {
        (0..<WireProtocol.surveyChannelCount).map { $0 == hot ? hotLevel : floor }
    }

    private func analyze(levels: [Int], home: Int = 0,
                         confirmed: [Int] = [], frames: [Int] = [],
                         status: ChannelSurvey.Status = .ok) -> ChannelSurvey.Result {
        ChannelSurvey.analyze(status: status, levels: levels, homeChannel: home,
                              confirmedChannels: confirmed, confirmedFrames: frames)
    }

    // MARK: - Ranking

    func testQuietestChannelRanksFirst() {
        var levels = [Int](repeating: -100, count: WireProtocol.surveyChannelCount)
        levels[42] = -120
        XCTAssertEqual(42, analyze(levels: levels).ranked.first?.channel)
    }

    func testAKnownInterfererSurfacesAsTheLoudestChannel() {
        let r = analyze(levels: quietBand(hot: 7))
        XCTAssertEqual(7, r.ranked.last?.channel)
    }

    /// Ties break on channel number so an unchanged RF environment produces an
    /// unchanged recommendation rather than shuffling every sweep.
    func testTiesBreakOnChannelNumber() {
        let flat = [Int](repeating: -100, count: WireProtocol.surveyChannelCount)
        XCTAssertEqual(Array(0..<5), analyze(levels: flat).ranked.prefix(5).map(\.channel))
    }

    func testHomeRankIsOneBased() {
        var levels = [Int](repeating: -100, count: WireProtocol.surveyChannelCount)
        levels[3] = -120
        XCTAssertEqual(1, analyze(levels: levels, home: 3).homeRank)
    }

    // MARK: - Only confirmed channels may be suggested

    /// The coarse pass dwells ~12 ms while a locator is on air ~138 ms per second, so it
    /// reads an occupied channel as quiet about three times in four. Suggesting an
    /// unconfirmed channel is how a sweep recommends the channel already in use.
    func testAnUnconfirmedChannelIsNeverSuggestedHoweverQuietItLooks() {
        var levels = [Int](repeating: -100, count: WireProtocol.surveyChannelCount)
        levels[9] = -125                                   // quietest in the whole band
        let r = analyze(levels: levels, confirmed: [11, 12], frames: [0, 0])
        XCTAssertEqual(9, r.ranked.first?.channel, "still ranks first")
        XCTAssertFalse(r.suggestions.contains { $0.channel == 9 }, "but is not offered")
    }

    func testNoConfirmedChannelsMeansNoSuggestions() {
        XCTAssertTrue(analyze(levels: quietBand(hot: 3)).suggestions.isEmpty)
    }

    func testSuggestionsAreCappedAtTheConfirmCount() {
        let flat = [Int](repeating: -110, count: WireProtocol.surveyChannelCount)
        let r = analyze(levels: flat, confirmed: Array(0..<10), frames: [Int](repeating: 0, count: 10))
        XCTAssertLessThanOrEqual(r.suggestions.count, ChannelSurvey.suggestionCount)
    }

    func testConfirmedChannelsOutsideTheLevelRangeAreIgnored() {
        let levels = [Int](repeating: -110, count: 8)
        let r = analyze(levels: levels, confirmed: [2, 99], frames: [0, 0])
        XCTAssertEqual([2], r.confirmed.map(\.channel))
    }

    // MARK: - Decoded frames outrank the level

    /// A decoded frame had to be transmitted on that exact channel — bleed does not
    /// survive the demodulator. RSSI cannot separate "a locator is using this channel"
    /// from "a locator near me is loud everywhere"; this can.
    func testAChannelWithALocatorOnItIsNeverSuggestedHoweverQuietItReads() {
        var levels = [Int](repeating: -100, count: WireProtocol.surveyChannelCount)
        levels[5] = -125
        let r = analyze(levels: levels, confirmed: [5, 6], frames: [3, 0])
        XCTAssertFalse(r.suggestions.contains { $0.channel == 5 })
        XCTAssertEqual([6], r.suggestions.map(\.channel))
    }

    /// Frames are matched to their channel by POSITION in the parallel arrays, not by
    /// value — swapping that silently blames the wrong channel.
    func testFramesAreMatchedToTheirChannelByPosition() {
        let levels = [Int](repeating: -110, count: WireProtocol.surveyChannelCount)
        let r = analyze(levels: levels, confirmed: [20, 30], frames: [0, 7])
        XCTAssertEqual([30], r.occupied.map(\.channel))
    }

    /// The converse does not hold: zero frames does not prove empty. A sparser emitter
    /// slips through the dwell and a non-locator device is invisible to this test.
    func testZeroFramesDoesNotByItselfMakeAChannelGood() {
        var levels = [Int](repeating: -110, count: WireProtocol.surveyChannelCount)
        levels[4] = -50                                    // loud, but no locator decoded
        let r = analyze(levels: levels, confirmed: [4], frames: [0])
        XCTAssertFalse(r.confirmed[0].occupiedByLocator)
        XCTAssertEqual(-50, r.confirmed[0].level, "the level is still the evidence")
    }

    // MARK: - Home channel

    /// Home normally decodes frames because that is where OUR locator transmits.
    /// Reporting it as "another locator" would be plainly wrong.
    func testTheHomeChannelIsReportedSeparatelyNotAsAnotherLocator() {
        let levels = [Int](repeating: -110, count: WireProtocol.surveyChannelCount)
        let r = analyze(levels: levels, home: 12, confirmed: [12, 13], frames: [4, 2])
        XCTAssertTrue(r.homeChannelInUse)
        XCTAssertEqual([13], r.occupied.map(\.channel))
    }

    func testAQuietHomeChannelIsNotReportedAsInUse() {
        let levels = [Int](repeating: -110, count: WireProtocol.surveyChannelCount)
        XCTAssertFalse(analyze(levels: levels, home: 12, confirmed: [12], frames: [0]).homeChannelInUse)
    }

    // MARK: - The all-hot and uniform-floor cases

    /// The scenario that prompted the whole line of work. The ranking is still correct
    /// and still offered — withholding it leaves a correct warning with no way to act.
    func testAllChannelsHotStillRanksAndStillSuggests() {
        let levels = [Int](repeating: -60, count: WireProtocol.surveyChannelCount)
        let r = analyze(levels: levels, confirmed: [1, 2, 3], frames: [0, 0, 0])
        XCTAssertTrue(r.allChannelsHot)
        XCTAssertFalse(r.suggestions.isEmpty, "a correct warning must still be actionable")
    }

    /// Flat and elevated is one transmitter raising everything equally — information,
    /// not a fault. The bench trace was −71/−74/−72/−71/−71.
    func testAFlatElevatedReadingIsAUniformFloor() {
        var levels = [Int](repeating: -110, count: WireProtocol.surveyChannelCount)
        for (i, v) in [(1, -71), (2, -74), (3, -72), (4, -71), (5, -71)] { levels[i] = v }
        let r = analyze(levels: levels, confirmed: [1, 2, 3, 4, 5], frames: [Int](repeating: 0, count: 5))
        XCTAssertTrue(r.allChannelsHot)
        XCTAssertTrue(r.uniformFloor)
    }

    /// Elevated WITH structure is real occupancy, and the ranking is telling us
    /// something. The bench trace was −52/−57/−71/−71/−71: 19 dB.
    func testAnElevatedReadingWithStructureIsNotAUniformFloor() {
        var levels = [Int](repeating: -110, count: WireProtocol.surveyChannelCount)
        for (i, v) in [(1, -52), (2, -57), (3, -71), (4, -71), (5, -71)] { levels[i] = v }
        let r = analyze(levels: levels, confirmed: [1, 2, 3, 4, 5], frames: [Int](repeating: 0, count: 5))
        XCTAssertTrue(r.allChannelsHot)
        XCTAssertFalse(r.uniformFloor)
        XCTAssertEqual(3, r.suggestions.first?.channel, "the quiet ones are still the answer")
    }

    /// Uniform needs the levels ELEVATED, not merely flat: a flat quiet band is an
    /// ordinary good band, not a near-field floor.
    func testUniformFloorNeedsElevatedLevels() {
        let levels = [Int](repeating: -110, count: WireProtocol.surveyChannelCount)
        let r = analyze(levels: levels, confirmed: [1, 2, 3], frames: [0, 0, 0])
        XCTAssertFalse(r.allChannelsHot)
        XCTAssertFalse(r.uniformFloor)
    }

    func testAllHotIsJudgedOnConfirmedChannelsOnly() {
        var levels = [Int](repeating: -50, count: WireProtocol.surveyChannelCount)
        levels[9] = -120                                   // one genuinely quiet, confirmed
        let r = analyze(levels: levels, confirmed: [9], frames: [0])
        XCTAssertFalse(r.allChannelsHot)
    }

    func testAllHotBoundaryIsInclusive() {
        let levels = [Int](repeating: ChannelSurvey.allHotDbm, count: WireProtocol.surveyChannelCount)
        XCTAssertTrue(analyze(levels: levels, confirmed: [0], frames: [0]).allChannelsHot)
    }

    // MARK: - Refusals and degenerate input

    func testRefusalProducesNoRanking() {
        for status in [ChannelSurvey.Status.refusedArmed, .refusedBusy, .unknown] {
            let r = analyze(levels: quietBand(hot: 1), confirmed: [2], frames: [0], status: status)
            XCTAssertTrue(r.ranked.isEmpty)
            XCTAssertTrue(r.suggestions.isEmpty)
        }
    }

    /// An unrecognised status byte must never present as a good reading.
    func testAnUnknownStatusByteIsNotOk() {
        XCTAssertEqual(.ok, ChannelSurvey.Status.from(0))
        XCTAssertEqual(.refusedArmed, ChannelSurvey.Status.from(1))
        XCTAssertEqual(.refusedBusy, ChannelSurvey.Status.from(2))
        XCTAssertEqual(.unknown, ChannelSurvey.Status.from(200))
    }

    func testEmptyLevelsDoNotCrashTheRanking() {
        let r = analyze(levels: [])
        XCTAssertTrue(r.ranked.isEmpty)
        XCTAssertNil(r.homeRank)
    }
}

/// The survey as the screen consumes it.
extension ChannelSurveyTests {

    /// A sweep that produced nothing usable is still a Result, not nil: "no response
    /// from the receiver" is information, and an empty section reads as a button that
    /// did nothing.
    func testAFailedSweepIsRenderableRatherThanNil() {
        let r = ChannelSurvey.failed(homeChannel: 7)
        XCTAssertEqual(.unknown, r.status)
        XCTAssertEqual(7, r.homeChannel)
        XCTAssertTrue(r.suggestions.isEmpty)
        XCTAssertTrue(r.ranked.isEmpty)
    }

    /// The bar is relative to this sweep: quietest is empty, loudest is full.
    func testTheBarSpansTheSweep() {
        var levels = [Int](repeating: -100, count: WireProtocol.surveyChannelCount)
        levels[0] = -120                                    // quietest
        levels[1] = -60                                     // loudest
        let r = analyze(levels: levels)
        XCTAssertEqual(0, r.relativeLevel(ChannelSurvey.Ranked(channel: 0, level: -120)))
        XCTAssertEqual(1, r.relativeLevel(ChannelSurvey.Ranked(channel: 1, level: -60)))
        XCTAssertEqual(0.5, r.relativeLevel(ChannelSurvey.Ranked(channel: 2, level: -90)),
                       accuracy: 0.01)
    }

    /// A genuinely flat band is the uniform-floor case and therefore common on a bench.
    /// Without the 1 dB floor on the span every bar would be NaN.
    func testAFlatBandDoesNotDivideByZero() {
        let flat = [Int](repeating: -71, count: WireProtocol.surveyChannelCount)
        let r = analyze(levels: flat)
        let value = r.relativeLevel(ChannelSurvey.Ranked(channel: 0, level: -71))
        XCTAssertFalse(value.isNaN)
        XCTAssertEqual(0, value)
    }
}
