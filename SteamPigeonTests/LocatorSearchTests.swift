import XCTest
@testable import SteamPigeon

/// The candidate list, which is the whole reason this search is usable, and the rules
/// that decide what a run MEANS once it has finished.
///
/// Every channel in the list costs a full broadcast period of deafness, so the candidate
/// tests are mostly about what the list must NOT contain: duplicates, invalid channels,
/// or more entries than the firmware will read.
///
/// Ported case for case from Android's `LocatorSearchTest.kt` (23 tests), because these
/// rules are the ones hardware disagreed with twice and the reversals are what must
/// survive the port.
final class LocatorSearchTests: XCTestCase {

    private let ours: UInt32 = 0x1111_1111
    private let theirs: UInt32 = 0x2222_2222

    // MARK: - Candidates

    func testTargetChannelIsSearchedFirst() {
        // The firmware stops on the first frame from the target, so the ordering is the
        // difference between one dwell and all of them.
        let c = LocatorSearch.candidates(currentChannel: 7, targetChannel: 21,
                                         knownChannels: [3, 9])
        XCTAssertEqual(21, c.first)
    }

    func testOtherLocatorsChannelsFollow() {
        let c = LocatorSearch.candidates(currentChannel: 7, targetChannel: 21,
                                         knownChannels: [3, 9])
        XCTAssertEqual([21, 3, 9, LocatorSearch.defaultChannel, 7], c)
    }

    /// A locator whose settings did not survive is on 0, and nothing else in the list
    /// would ever point there (ADR-0025).
    func testDefaultChannelIsAlwaysTried() {
        let c = LocatorSearch.candidates(currentChannel: 40, knownChannels: [12])
        XCTAssertTrue(c.contains(LocatorSearch.defaultChannel))
    }

    /// We are already sitting here hearing nothing, so it is the least likely answer —
    /// but not an impossible one, so it is included rather than dropped.
    func testCurrentChannelIsLast() {
        let c = LocatorSearch.candidates(currentChannel: 40, knownChannels: [12])
        XCTAssertEqual(40, c.last)
    }

    /// The sources overlap constantly: a locator's last channel is usually the one the
    /// receiver is still on. A duplicate would spend 1.4 s proving the same thing twice.
    func testDuplicatesCollapse() {
        let c = LocatorSearch.candidates(currentChannel: 12, targetChannel: 12,
                                         knownChannels: [12, 12], attemptedChannel: 12)
        XCTAssertEqual([12, LocatorSearch.defaultChannel], c)
    }

    func testOutOfRangeChannelsAreDropped() {
        let c = LocatorSearch.candidates(currentChannel: 5,
                                         targetChannel: 64,          // one past the band
                                         knownChannels: [-1, 63])
        XCTAssertFalse(c.contains(64))
        XCTAssertFalse(c.contains(-1))
        XCTAssertTrue(c.contains(63))
    }

    /// The firmware truncates a longer list, so a list built past the cap would silently
    /// not be searched — the worst kind of miss, since the UI would have promised those
    /// channels.
    func testListIsCappedToWhatTheFirmwareReads() {
        let c = LocatorSearch.candidates(currentChannel: 5, knownChannels: Array(10...59))
        XCTAssertEqual(WireProtocol.searchMaxChannels, c.count)
    }

    /// The half-landed channel move: the locator took the new channel and the receiver
    /// did not, so the attempted one is a strong guess.
    func testAttemptedChannelIsTriedBeforeTheDefault() {
        let c = LocatorSearch.candidates(currentChannel: 4, knownChannels: [],
                                         attemptedChannel: 33)
        XCTAssertEqual([33, LocatorSearch.defaultChannel, 4], c)
    }

    // MARK: - What a finished run means

    private func shortRun(hits: [LocatorSearch.Hit] = [],
                          status: LocatorSearch.Status = .done,
                          wholeBand: Bool = false,
                          target: UInt32 = 0) -> LocatorSearch.Run {
        LocatorSearch.Run(running: false, searched: 4, total: 4, hits: hits,
                          status: status, wholeBand: wholeBand, targetLocatorId: target)
    }

    func testMissedIsOnlyTrueForAShortRunThatFoundNothing() {
        let short = shortRun()
        XCTAssertTrue(short.missed)
        // Widening after a whole-band run would mean sweeping the band twice.
        XCTAssertFalse(shortRun(wholeBand: true).missed)
        // A refusal is not a miss: nothing was searched, so there is nothing to widen.
        XCTAssertFalse(shortRun(status: .refusedArmed).missed)
        XCTAssertFalse(shortRun(hits: [hit(channel: 4, id: 1, rssi: -70, snr: 8)]).missed)
    }

    /// The case the feature exists for: hunting Prometheus while Twist 0 is audible on
    /// the current channel. Counting hits calls that success and leaves the user hunting
    /// a locator the app believes it already found.
    func testATargetedRunThatFindsSomebodyElseHasStillMissed() {
        let run = shortRun(hits: [hit(channel: 34, id: theirs, name: "Twist 0",
                                      rssi: -60, snr: 8)],
                           target: ours)
        XCTAssertTrue(run.missed)
        XCTAssertTrue(run.canWiden)
    }

    func testATargetedRunThatFindsTheTargetHasNotMissed() {
        let run = shortRun(hits: [hit(channel: 48, id: ours, name: "Prometheus",
                                      rssi: -55, snr: 8)],
                           target: ours)
        XCTAssertFalse(run.missed)
        // Still widenable: finding it does not prove there is nothing else worth a look.
        XCTAssertTrue(run.canWiden)
    }

    func testAnUntargetedRunThatFindsAnythingHasNotMissed() {
        let run = shortRun(hits: [hit(channel: 34, id: theirs, name: "Twist 0",
                                      rssi: -60, snr: 8)])
        XCTAssertFalse(run.missed)
        XCTAssertTrue(run.canWiden)
    }

    /// Any **completed** short run qualifies, not only a missed one: gating the band
    /// sweep on an empty result left no way to reach it at all while anything was
    /// audible. A *cancelled* run does not — answering "stop" with an 80-second sweep is
    /// not reading the room.
    func testWideningIsOfferedAfterAnyCompletedShortRun() {
        XCTAssertTrue(shortRun().canWiden)
        XCTAssertTrue(shortRun(hits: [hit(channel: 1, id: theirs, rssi: -70, snr: 8)]).canWiden)

        var running = shortRun()
        running.running = true
        XCTAssertFalse(running.canWiden)
        XCTAssertFalse(shortRun(wholeBand: true).canWiden)
        XCTAssertFalse(shortRun(status: .cancelled).canWiden)
        XCTAssertFalse(shortRun(status: .refusedArmed).canWiden)
    }

    // MARK: - Near-field artifacts

    private func bandRun(_ hits: LocatorSearch.Hit...) -> LocatorSearch.Run {
        LocatorSearch.Run(running: false, searched: 64, total: 64, hits: hits,
                          status: .done, wholeBand: true)
    }

    /// The measured case: a locator on 57 also reported on 17, 8 MHz away, because it was
    /// close enough to overload the front end.
    func testOneLocatorOnTwoChannelsFlagsAllButTheStrongest() {
        let r = bandRun(hit(channel: 17, id: ours, name: "Prometheus", rssi: -95, snr: -7),
                        hit(channel: 57, id: ours, name: "Prometheus", rssi: -60, snr: 9))
        XCTAssertEqual([17], r.suspectChannels)
    }

    func testALocatorOnOneChannelIsNeverSuspect() {
        let r = bandRun(hit(channel: 57, id: ours, name: "Prometheus", rssi: -60, snr: 9))
        XCTAssertTrue(r.suspectChannels.isEmpty)
    }

    /// The census case. Grouping is per locator, so two rockets on two channels is the
    /// normal answer and must not be flagged as a contradiction.
    func testTwoDifferentLocatorsOnTwoChannelsAreBothFine() {
        let r = bandRun(hit(channel: 12, id: ours, name: "Prometheus", rssi: -70, snr: 5),
                        hit(channel: 34, id: theirs, name: "Twist 0", rssi: -65, snr: 7))
        XCTAssertTrue(r.suspectChannels.isEmpty)
    }

    /// id 0 means the frame did not say who. Two of them cannot be known to be the same
    /// locator, so neither can be called the other's stray.
    func testHitsWithNoIdAreNeverGrouped() {
        let r = bandRun(hit(channel: 12, id: 0, rssi: -90, snr: -5),
                        hit(channel: 34, id: 0, rssi: -60, snr: 8))
        XCTAssertTrue(r.suspectChannels.isEmpty)
    }

    func testThreeChannelsLeaveExactlyOneUnflagged() {
        let r = bandRun(hit(channel: 5, id: ours, name: "Prometheus", rssi: -99, snr: -9),
                        hit(channel: 17, id: ours, name: "Prometheus", rssi: -95, snr: -7),
                        hit(channel: 57, id: ours, name: "Prometheus", rssi: -60, snr: 9))
        XCTAssertEqual([5, 17], r.suspectChannels)
    }

    /// Pins the ordering rule deliberately. Bench 2026-08-28 confirmed it against
    /// hardware: the channel this rule flags is the one that disappears when the locator
    /// is moved away, so it picks the real channel. This test is still where the rule
    /// would change if an artifact were ever seen arriving STRONGER than the true
    /// channel — not observed on that rig.
    func testRankingIsRssiPlusSnrSoAStrongNoisyHitCanLose() {
        let r = bandRun(hit(channel: 17, id: ours, rssi: -50, snr: -12),   // sum −62
                        hit(channel: 57, id: ours, rssi: -70, snr: 10))    // sum −60, wins
        XCTAssertEqual([17], r.suspectChannels)
    }

    // MARK: - Connected

    /// Bench 2026-08-28: one locator close to the receiver was reported on two channels,
    /// both rows read Connected because both hits carry the same id, and sitting on the
    /// false channel left no way to reach the real one.
    func testOnlyTheRowOnTheReceiversOwnChannelReadsConnected() {
        let onFalse = hit(channel: 17, id: ours, name: "Prometheus", rssi: -95, snr: -7)
        let onReal = hit(channel: 57, id: ours, name: "Prometheus", rssi: -60, snr: 9)

        // Receiver parked on the false channel: that row is where it is connected, and
        // the real channel must still offer a way to get there.
        XCTAssertTrue(onFalse.connectedOn(currentChannel: 17, connectedLocatorId: ours))
        XCTAssertFalse(onReal.connectedOn(currentChannel: 17, connectedLocatorId: ours))

        // And the other way round once it has moved.
        XCTAssertFalse(onFalse.connectedOn(currentChannel: 57, connectedLocatorId: ours))
        XCTAssertTrue(onReal.connectedOn(currentChannel: 57, connectedLocatorId: ours))
    }

    /// An unknown locator: the receiver arrives on the channel while an ADR-0006 password
    /// challenge is still outstanding, and nothing is connected yet.
    func testBeingTunedToTheChannelIsNotBeingConnected() {
        let h = hit(channel: 57, id: theirs, name: "Borrowed", rssi: -60, snr: 9)
        XCTAssertFalse(h.connectedOn(currentChannel: 57, connectedLocatorId: nil))
        XCTAssertFalse(h.connectedOn(currentChannel: 57, connectedLocatorId: ours))
        XCTAssertTrue(h.connectedOn(currentChannel: 57, connectedLocatorId: theirs))
    }

    /// id 0 is "the frame did not say who", which cannot match anything.
    func testAHitWithNoIdIsNeverConnected() {
        let h = hit(channel: 57, id: 0, rssi: -60, snr: 9)
        XCTAssertFalse(h.connectedOn(currentChannel: 57, connectedLocatorId: nil))
        XCTAssertFalse(h.connectedOn(currentChannel: 57, connectedLocatorId: 0))
    }

    /// `total` is 0 until the first result arrives; a bare division would render the
    /// progress bar as NaN.
    func testProgressFractionSurvivesAnEmptyRun() {
        XCTAssertEqual(0, LocatorSearch.Run(running: true).fraction, accuracy: 0.0001)
    }

    // MARK: - Status decoding

    /// The wire values are the contract with the receiver firmware. `Cancelled` in
    /// particular must decode as itself: it is the status a run gets when an operator
    /// command ended the sweep, and reading it as a refusal would blame the wrong thing.
    func testStatusDecodesTheFirmwareValues() {
        XCTAssertEqual(.progress, LocatorSearch.Status.from(0))
        XCTAssertEqual(.done, LocatorSearch.Status.from(1))
        XCTAssertEqual(.refusedArmed, LocatorSearch.Status.from(2))
        XCTAssertEqual(.refusedBusy, LocatorSearch.Status.from(3))
        XCTAssertEqual(.cancelled, LocatorSearch.Status.from(4))
        XCTAssertEqual(.unknown, LocatorSearch.Status.from(5))
    }

    // MARK: - Frame decoding

    /// Field ORDER, not just total size: a total-size assertion cannot catch rssi and snr
    /// swapping places, and the suspect-channel rule depends on both.
    func testResultFrameDecodesEveryFieldInOrder() throws {
        var frame = [UInt8](repeating: 0, count: 39)
        frame[0] = WireProtocol.systemId
        frame[1] = MsgType.locatorSearchResult.rawValue
        frame[6] = 0            // status: Progress
        frame[7] = 57           // channel
        frame[8] = 3            // searched
        frame[9] = 6            // total
        frame[10] = 1           // found
        frame[11] = 1           // armed
        frame[12] = 0xC4        // rssi −60, little-endian int16
        frame[13] = 0xFF
        frame[14] = 0xF9        // snr −7, int8
        frame[15] = 0x11        // locator_id 0x11111111
        frame[16] = 0x11
        frame[17] = 0x11
        frame[18] = 0x11
        for (i, b) in Array("Prometheus".utf8).enumerated() { frame[19 + i] = b }

        let r = try XCTUnwrap(LocatorSearchResult.parse(frame))
        XCTAssertEqual(.progress, r.status)
        XCTAssertEqual(57, r.channel)
        XCTAssertEqual(3, r.searched)
        XCTAssertEqual(6, r.total)
        XCTAssertTrue(r.found)
        XCTAssertTrue(r.armed)
        XCTAssertEqual(-60, r.rssi)
        XCTAssertEqual(-7, r.snr)
        XCTAssertEqual(ours, r.locatorId)
        XCTAssertEqual("Prometheus", r.deviceName)
    }

    /// A short frame from mismatched firmware must yield nil, not trap: an out-of-range
    /// index is a crash in Swift where it is a caught exception on Android, and this app
    /// keeps working through a bad link by design.
    func testAShortResultFrameYieldsNilRatherThanTrapping() {
        XCTAssertNil(LocatorSearchResult.parse([UInt8](repeating: 0, count: 20)))
    }

    // MARK: -

    private func hit(channel: Int, id: UInt32, name: String = "",
                     rssi: Int, snr: Int, armed: Bool = false) -> LocatorSearch.Hit {
        LocatorSearch.Hit(channel: channel, locatorId: id, deviceName: name,
                          rssi: rssi, snr: snr, armed: armed)
    }
}

/// The streamed state machine: how a run is folded together from one message per channel,
/// and what a visit to the screen is allowed to do to it.
@MainActor
final class LocatorSearchLifecycleTests: XCTestCase {

    /// One `LocatorSearchResult` frame. No CRC — `ingestForTesting` stands in for a frame
    /// that has already passed the framer's gate.
    private func resultFrame(status: UInt8, channel: UInt8 = 0, searched: UInt8 = 0,
                             total: UInt8 = 0, found: Bool = false, armed: Bool = false,
                             rssi: Int16 = 0, snr: Int8 = 0, id: UInt32 = 0,
                             name: String = "") -> [UInt8] {
        var f = [UInt8](repeating: 0,
                        count: WireProtocol.headerSize + WireProtocol.locatorSearchResultPayloadSize)
        f[0] = WireProtocol.systemId
        f[1] = MsgType.locatorSearchResult.rawValue
        f[6] = status
        f[7] = channel
        f[8] = searched
        f[9] = total
        f[10] = found ? 1 : 0
        f[11] = armed ? 1 : 0
        f[12] = UInt8(truncatingIfNeeded: UInt16(bitPattern: rssi))
        f[13] = UInt8(truncatingIfNeeded: UInt16(bitPattern: rssi) >> 8)
        f[14] = UInt8(bitPattern: snr)
        for (i, b) in OutboundMessage.u32le(id).enumerated() { f[15 + i] = b }
        for (i, b) in Array(name.utf8).prefix(WireProtocol.deviceNameLength).enumerated() {
            f[19 + i] = b
        }
        return f
    }

    /// Hits accumulate as they stream, and the receiver's denominator wins: the firmware
    /// dedupes and range-checks the list, so it may search fewer channels than were asked
    /// for, and the app's own count would then show a bar that never fills.
    func testStreamedResultsAccumulateAndTrustTheReceiversTotal() {
        let m = LinkViewModel()
        m.setLocatorSearchForTesting(LocatorSearch.Run(running: true, total: 6))

        m.ingestForTesting(resultFrame(status: 0, channel: 12, searched: 1, total: 4))
        XCTAssertEqual(4, m.locatorSearch?.total)
        XCTAssertEqual(1, m.locatorSearch?.searched)
        XCTAssertTrue(m.locatorSearch?.hits.isEmpty == true)

        m.ingestForTesting(resultFrame(status: 0, channel: 57, searched: 2, total: 4,
                                       found: true, rssi: -60, snr: 9,
                                       id: 0x1111_1111, name: "Prometheus"))
        XCTAssertEqual([57], m.locatorSearch?.hits.map(\.channel))
        XCTAssertEqual("Prometheus", m.locatorSearch?.hits.first?.deviceName)
        XCTAssertEqual(-60, m.locatorSearch?.hits.first?.rssi)
        XCTAssertEqual(9, m.locatorSearch?.hits.first?.snr)
        // Still running: only a terminator ends it.
        XCTAssertEqual(true, m.locatorSearch?.running)
    }

    /// The terminator ends the run and carries the reason. `Cancelled` in particular has
    /// to survive as itself — it is what the receiver says when an operator command ended
    /// the sweep, and the screen tells the user exactly that.
    func testATerminatorEndsTheRunAndKeepsItsStatus() {
        let m = LinkViewModel()
        m.setLocatorSearchForTesting(LocatorSearch.Run(running: true, total: 4))
        m.ingestForTesting(resultFrame(status: 4))          // Cancelled
        XCTAssertEqual(false, m.locatorSearch?.running)
        XCTAssertEqual(.cancelled, m.locatorSearch?.status)
    }

    /// A message arriving with no run in flight is dropped rather than inventing one:
    /// this app did not start that sweep, or has been told to forget it.
    func testAResultWithNoRunInFlightIsIgnored() {
        let m = LinkViewModel()
        m.ingestForTesting(resultFrame(status: 0, channel: 3, searched: 1, total: 4))
        XCTAssertNil(m.locatorSearch)
    }

    /// **A visit must never orphan a running search.** Clearing unconditionally left the
    /// receiver sweeping — deaf, for up to ~90 s — while the app ignored the stream and
    /// the terminator alike, because every result arriving against a nil run is dropped.
    func testAVisitLeavesARunningSearchAloneAndClearsAFinishedOne() {
        let m = LinkViewModel()

        m.setLocatorSearchForTesting(LocatorSearch.Run(running: true, total: 64))
        m.clearScansForNewVisit()
        XCTAssertNotNil(m.locatorSearch, "a run in flight must survive re-entering the screen")

        m.setLocatorSearchForTesting(LocatorSearch.Run(running: false, status: .done))
        m.clearScansForNewVisit()
        XCTAssertNil(m.locatorSearch, "a finished run is stale and must not read as current")
    }

    /// Starting a second search while one is running would leave the first run's results
    /// being folded into the second's state.
    func testASecondSearchIsRefusedWhileOneIsRunning() {
        let m = LinkViewModel()
        m.setLocatorSearchForTesting(LocatorSearch.Run(running: true, total: 64,
                                                       wholeBand: true))
        m.startLocatorSearch(channels: [1, 2, 3])
        XCTAssertEqual(true, m.locatorSearch?.running)
        XCTAssertEqual(64, m.locatorSearch?.total)
    }

    /// With no transport the request never goes out, so no terminator is coming: the run
    /// has to settle locally rather than sit at "searching" until the silence timeout.
    func testASearchThatCannotBeSentSettlesRatherThanHanging() {
        let m = LinkViewModel()
        m.startLocatorSearch(channels: [1, 2])
        XCTAssertEqual(false, m.locatorSearch?.running)
        XCTAssertEqual(.unknown, m.locatorSearch?.status)
    }

    /// Pointing the receiver where it already is would start a confirm cycle with nothing
    /// to confirm — the button would report "Update not acknowledged" for a change that
    /// was never needed.
    func testPointingAtTheCurrentChannelIsANoOp() {
        let m = LinkViewModel()
        m.pointReceiverAtChannel(m.remoteReceiverConfig.channel)
        XCTAssertEqual(ConfigMessageState.idle, m.receiverConfigMessageState)
    }
}
