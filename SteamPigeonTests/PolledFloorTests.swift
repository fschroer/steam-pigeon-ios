import XCTest
@testable import SteamPigeon

/// The channel measurement that needs no locator (ADR-0019).
///
/// `ReceiverInfo` is the only message the receiver sends on its own behalf, so its
/// noise floor is the sole reading available during locator silence — exactly when
/// "something is sitting on our channel" and "the locator is switched off" are hardest
/// to tell apart. These pin the two rules that make it usable, both of which are
/// counter-intuitive enough to have been got wrong on Android first.
final class PolledFloorTests: XCTestCase {

    /// **A polled floor is judged against a baseline from its own regime.**
    ///
    /// Polled readings come from the receiver's continuous sampling and read HIGHER
    /// than the safe-window figure a broadcast carries. Mixing them into one
    /// minimum-keeping baseline pins that baseline at the broadcast value, so every
    /// polled reading afterwards looks elevated — permanently — and a channel with
    /// nothing on it is reported as interference for the rest of the session.
    func testMixingTheTwoRegimesWouldPinTheBaselineAndFalselyElevate() {
        let broadcastFloor = -120       // safe-window statistic: quiet
        let polledFloor = -100          // continuous peak on the SAME quiet channel

        // One shared baseline: the polled reading clears the elevation margin.
        let shared = LinkQuality.updateQuietestFloor(
            current: LinkQuality.updateQuietestFloor(current: LinkQuality.noiseFloorUnknown,
                                                     sample: broadcastFloor),
            sample: polledFloor)
        XCTAssertEqual(broadcastFloor, shared, "the minimum keeps the broadcast value")
        XCTAssertGreaterThanOrEqual(polledFloor - shared, LinkQuality.elevatedFloorMarginDb,
                                    "which makes an ordinary polled reading look elevated")

        // Its own baseline: the same reading is the quietest yet, so nothing is raised.
        let ownBaseline = LinkQuality.updateQuietestFloor(current: LinkQuality.noiseFloorUnknown,
                                                          sample: polledFloor)
        XCTAssertLessThan(polledFloor - ownBaseline, LinkQuality.elevatedFloorMarginDb)
    }

    /// **The absolute test is dropped for a polled floor.** `busyFloorDbm` is calibrated
    /// for the safe-window statistic; a continuously-sampled peak clears it on a channel
    /// with nothing on it whatsoever, so trusting it would call every quiet channel busy.
    func testTheAbsoluteFloorTestIsNotTrustedForAPolledReading() {
        let peak = LinkQuality.busyFloorDbm + 5      // loud by the absolute test alone

        let trusted = LinkQuality.classify(
            rssi: -100, snr: 10, noiseFloor: peak, quietestFloor: peak,
            packetFresh: false, floorFresh: true, absoluteFloorTrusted: true)
        XCTAssertEqual(.congested, trusted, "the absolute test alone calls it occupied")

        let polled = LinkQuality.classify(
            rssi: -100, snr: 10, noiseFloor: peak, quietestFloor: peak,
            packetFresh: false, floorFresh: true, absoluteFloorTrusted: false)
        XCTAssertEqual(.normal, polled, "the same reading, judged relatively, is quiet")
    }

    /// A floor that has risen against its OWN baseline is still reported, so dropping
    /// the absolute test does not make the polled path blind.
    func testAPolledFloorThatHasRisenIsStillReported() {
        let quiet = -120
        let risen = quiet + LinkQuality.elevatedFloorMarginDb
        XCTAssertEqual(.congested, LinkQuality.classify(
            rssi: -100, snr: 10, noiseFloor: risen, quietestFloor: quiet,
            packetFresh: false, floorFresh: true, absoluteFloorTrusted: false))
    }

    /// Measurements age. Once the last packet has lapsed, nothing derived from it may
    /// still assert interference — that is what let a locator switched off go on being
    /// reported as a jammed channel.
    func testAStalePacketCannotAssertInterference() {
        // Loud and dirty: interference while the packet is fresh.
        XCTAssertEqual(.interference, LinkQuality.classify(
            rssi: -50, snr: 0, noiseFloor: LinkQuality.noiseFloorUnknown,
            quietestFloor: LinkQuality.noiseFloorUnknown,
            packetFresh: true, floorFresh: false))
        // The same values, aged out: there is no packet left to describe.
        XCTAssertEqual(.normal, LinkQuality.classify(
            rssi: -50, snr: 0, noiseFloor: LinkQuality.noiseFloorUnknown,
            quietestFloor: LinkQuality.noiseFloorUnknown,
            packetFresh: false, floorFresh: false))
    }

    /// A foreign locator outranks every RSSI-derived signal and does not age with the
    /// packet: it is occupancy decoded and identified, not inferred from power.
    func testADecodedForeignLocatorStillCounts() {
        XCTAssertEqual(.congested, LinkQuality.classify(
            rssi: -100, snr: 10, noiseFloor: LinkQuality.noiseFloorUnknown,
            quietestFloor: LinkQuality.noiseFloorUnknown,
            foreignLocator: true, packetFresh: false, floorFresh: false))
    }

    /// The poll cadence has to keep up with the freshness window, or the note blinks
    /// on and off between probes. The ADR-0012 watchdog's ~10 s is far too slow.
    func testThePollCadenceOutpacesTheFreshnessWindow() {
        XCTAssertLessThan(2.0, LinkQuality.staleMeasurement,
                          "channel-watch tick must be shorter than the freshness window")
    }
}
