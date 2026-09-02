import XCTest
import CoreBluetooth
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

    /// The coarse pass dwells ~12 ms while a disarmed locator is on air ~200 ms per
    /// second, so it reads an occupied channel as quiet about four times in five. Suggesting an
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
    // MARK: - Decoding the 104-byte response (ADR-0029)

    /// Build a `ChannelSurveyResponse` exactly as the receiver lays it out, so the
    /// offsets are pinned against the firmware rather than against `parse`'s own idea of
    /// them.
    private func responseFrame(status: UInt8 = 0, home: UInt8 = 0,
                               levels: [Int8],
                               confirmedChannels: [UInt8],
                               confirmedFrames: [UInt8],
                               confirmedIds: [UInt32]) -> [UInt8] {
        var f = [UInt8](repeating: 0,
                        count: WireProtocol.headerSize + WireProtocol.channelSurveyPayloadSize)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.channelSurvey.rawValue
        f[6] = status
        f[7] = UInt8(levels.count)
        f[8] = home
        for (i, l) in levels.enumerated() { f[9 + i] = UInt8(bitPattern: l) }
        var o = 9 + WireProtocol.surveyChannelCount
        f[o] = UInt8(confirmedChannels.count); o += 1
        for (i, c) in confirmedChannels.enumerated() { f[o + i] = c }
        o += WireProtocol.surveyConfirmCount
        for (i, c) in confirmedFrames.enumerated() { f[o + i] = c }
        o += WireProtocol.surveyConfirmCount
        for (i, id) in confirmedIds.enumerated() {
            for (b, byte) in OutboundMessage.u32le(id).enumerated() { f[o + i * 4 + b] = byte }
        }
        return f
    }

    /// The whole reason the message grew: a confirmed channel now names its occupant, so
    /// "another locator is on 12" can become "your other rocket is on 12".
    func testConfirmedLocatorIdsDecodeAgainstTheirOwnChannels() throws {
        var levels = [Int8](repeating: -110, count: WireProtocol.surveyChannelCount)
        levels[12] = -60
        let f = responseFrame(home: 34, levels: levels,
                              confirmedChannels: [12, 40],
                              confirmedFrames: [3, 0],
                              confirmedIds: [0x2222_2222, 0])
        let r = try XCTUnwrap(ChannelSurvey.parse(f))
        XCTAssertEqual(104, f.count)
        XCTAssertEqual(0x2222_2222, r.confirmed.first { $0.channel == 12 }?.locatorId)
        // A channel with nothing decoded on it carries no id — not a stale neighbour's.
        XCTAssertEqual(0, r.confirmed.first { $0.channel == 40 }?.locatorId)
    }

    /// A receiver running firmware from before this field simply ends the frame early.
    /// The ids come back empty and the rest of the sweep still reads — an out-of-range
    /// index would trap in Swift where Android merely caught an exception.
    func testAnOldShorterResponseStillDecodesWithoutIds() throws {
        var levels = [Int8](repeating: -110, count: WireProtocol.surveyChannelCount)
        levels[12] = -60
        let full = responseFrame(home: 34, levels: levels,
                                 confirmedChannels: [12], confirmedFrames: [3],
                                 confirmedIds: [0x2222_2222])
        let old = Array(full.prefix(84))          // the pre-ADR-0029 size
        let r = try XCTUnwrap(ChannelSurvey.parse(old))
        XCTAssertEqual(1, r.confirmed.count)
        XCTAssertEqual(12, r.confirmed.first?.channel)
        XCTAssertEqual(0, r.confirmed.first?.locatorId)
    }
}

/// Putting the survey away.
@MainActor
final class ChannelSurveyLifecycleTests: XCTestCase {

    /// The ranking describes the band BEFORE a move. Leaving it up beside a "now on
    /// channel N" message invites a second pick against a stale picture — and on the
    /// receiver-only path the channel it recommended has already been taken.
    func testPickingAChannelPutsTheSurveyAway() {
        let m = LinkViewModel()
        m.setChannelSurveyForTesting(
            ChannelSurvey.analyze(status: .ok,
                                  levels: [Int](repeating: -110, count: WireProtocol.surveyChannelCount),
                                  homeChannel: 0, confirmedChannels: [1], confirmedFrames: [0]))
        XCTAssertNotNil(m.channelSurvey)
        m.clearChannelSurvey()
        XCTAssertNil(m.channelSurvey)
    }

    /// A fresh sweep must not show the previous one's ranking while it runs.
    func testStartingASweepClearsTheOldResult() {
        let m = LinkViewModel()
        m.setChannelSurveyForTesting(ChannelSurvey.failed(homeChannel: 3))
        m.requestChannelSurvey()
        XCTAssertNotEqual(ChannelSurvey.Status.ok, m.channelSurvey?.status ?? .ok,
                          "the stale ranking must not survive into the new sweep")
    }

    /// A `Cancelled` frame that follows a cancel WE sent is worded as the user's own
    /// Stop, not as the firmware giving way to a queued command.
    ///
    /// This is the whole reason `cancelledByUser` exists. The receiver reports one
    /// status byte for all three causes, so without the substitution the user who just
    /// pressed Stop is told "Scan stopped so your command could reach the locator" —
    /// a specific claim about the hardware, and a false one.
    func testAUserCancelIsWordedAsTheUsersOwn() {
        let m = model(accepts: true)
        m.setSurveyInProgressForTesting(true)
        m.cancelChannelSurvey()
        m.ingestForTesting(cancelledResponseFrame())
        XCTAssertEqual(.cancelledByUser, m.channelSurvey?.status)
        XCTAssertEqual(false, m.surveyInProgress)
    }

    /// The same frame with no cancel of ours outstanding keeps the receiver's own
    /// meaning. The firmware cancels sweeps for a queued operator command and for a
    /// receiver channel change, and neither is something the user did.
    func testAnUnsolicitedCancelKeepsTheReceiversOwnWording() {
        let m = model(accepts: true)
        m.setSurveyInProgressForTesting(true)
        m.ingestForTesting(cancelledResponseFrame())
        XCTAssertEqual(.cancelled, m.channelSurvey?.status)
    }

    /// One cancel does not colour the next sweep. Without the reset, a sweep that ended
    /// for a queued command would be reported as the user's Stop for the rest of the
    /// session.
    func testTheCancelFlagDoesNotSurviveIntoTheNextSweep() {
        let m = model(accepts: true)
        m.setSurveyInProgressForTesting(true)
        m.cancelChannelSurvey()
        m.ingestForTesting(cancelledResponseFrame())
        XCTAssertEqual(.cancelledByUser, m.channelSurvey?.status)

        m.setSurveyInProgressForTesting(true)
        m.ingestForTesting(cancelledResponseFrame())
        XCTAssertEqual(.cancelled, m.channelSurvey?.status)
    }

    /// Stop tapped as the sweep finishes: the receiver answers the completed sweep AND
    /// the cancel it had nothing left to cancel, and the second answer must not land.
    ///
    /// The firmware answers an idle cancel on purpose — silence is the one reply an app
    /// cannot tell apart from firmware that never heard of the message — so this stray
    /// response is a designed consequence, not a fault. Without the guard it replaces a
    /// good ranking with "Scan stopped", which is the opposite of what happened.
    func testAStrayCancelDoesNotOverwriteACompletedSweep() {
        let m = model(accepts: true)
        m.setSurveyInProgressForTesting(true)
        m.cancelChannelSurvey()

        var levels = [Int8](repeating: -110, count: WireProtocol.surveyChannelCount)
        levels[7] = -60
        m.ingestForTesting(okResponseFrame(levels: levels))
        XCTAssertEqual(.ok, m.channelSurvey?.status, "the completed sweep should land")

        m.ingestForTesting(cancelledResponseFrame())
        XCTAssertEqual(.ok, m.channelSurvey?.status,
                       "the cancel's own answer describes nothing and must not land")
    }

    /// A cancel the transport will not take is a cancel that never happened, and the
    /// sweep must not be left reading "Scanning…" until the 15 s timeout — the user has
    /// already said they want it to stop.
    ///
    /// `LocatorTransport.send` is deliberately not `@discardableResult`, so this path
    /// exists to be checked rather than discarded; the equivalent Android branch settles
    /// the same way.
    func testACancelThatCannotBeSentSettlesRatherThanHanging() {
        let m = model(accepts: false)
        m.setSurveyInProgressForTesting(true)
        m.cancelChannelSurvey()
        XCTAssertFalse(m.surveyInProgress, "a cancel that never left the phone must not hang")
        XCTAssertEqual(.unknown, m.channelSurvey?.status)
    }

    /// A per-test `UserDefaults` suite, as `SendFailureTests` does: these models read and
    /// write stored locator state, and `.standard` would carry it between tests.
    /// `LinkViewModel` holds the transport strongly, so nothing here needs to retain it.
    private func model(accepts: Bool) -> LinkViewModel {
        let t = StubTransport()
        t.accepts = accepts
        return LinkViewModel(
            defaults: UserDefaults(suiteName: "ChannelSurveyTests.\(UUID().uuidString)")!,
            transport: t)
    }

    /// This repo keeps its test doubles file-local — `SendFailureTests.DeadTransport` is
    /// private — so this is the survey suite's own copy rather than a shared helper.
    private final class StubTransport: LocatorTransport {
        var onFrame: (([UInt8]) -> Void)?
        var onStateChange: ((TransportState) -> Void)?
        var onNameChange: ((String?) -> Void)?
        var onDiscover: (([CBPeripheral]) -> Void)?
        var onHealthProbe: (() -> Void)?
        var onBadFrameCount: ((Int) -> Void)?
        var onReject: ((PacketFramer.Reject) -> Void)?
        var onDroppedWrites: ((Int) -> Void)?
        var connectedName: String?

        private(set) var attempted = 0
        var accepts = false

        func send(_ bytes: [UInt8]) -> Bool { attempted += 1; return accepts }
        func startScan() {}
        func connectToDiscovered(_ id: UUID) {}
        func disconnect() {}
    }

    /// A completed sweep, so the race above has something real to be overwritten.
    private func okResponseFrame(levels: [Int8]) -> [UInt8] {
        var f = [UInt8](repeating: 0,
                        count: WireProtocol.headerSize + WireProtocol.channelSurveyPayloadSize)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.channelSurvey.rawValue
        f[6] = 0        // ChannelSurveyStatus::Ok
        f[7] = UInt8(levels.count)
        for (i, l) in levels.enumerated() { f[9 + i] = UInt8(bitPattern: l) }
        let o = 9 + WireProtocol.surveyChannelCount
        f[o] = 1        // confirmed_count
        f[o + 1] = 7    // confirmed_channel[0]
        return f
    }

    /// A `ChannelSurveyResponse` carrying `Cancelled`. Unsealed, like the neighbouring
    /// `responseFrame`: `ingest` dispatches on the type byte and the CRC was checked by
    /// the framer well before it.
    private func cancelledResponseFrame() -> [UInt8] {
        var f = [UInt8](repeating: 0,
                        count: WireProtocol.headerSize + WireProtocol.channelSurveyPayloadSize)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.channelSurvey.rawValue
        f[6] = 3        // ChannelSurveyStatus::Cancelled
        f[7] = 0        // channel_count — nothing measured
        return f
    }
}
