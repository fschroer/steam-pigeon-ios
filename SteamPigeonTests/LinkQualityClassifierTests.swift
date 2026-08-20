import XCTest
@testable import SteamPigeon

/// ADR-0019 classification. The ADR's own final section says its framing was too
/// narrow — everything about measuring *power* is close to useless against another
/// locator, because **LoRa capture is strong: co-channel interference displaces
/// rather than corrupts.** Four bench rounds went into measurements that could not
/// fire. These tests encode the corrected rules.
final class LinkQualityClassifierTests: XCTestCase {

    private let unknown = LinkQuality.noiseFloorUnknown

    func testConstantsMatchAndroid() {
        XCTAssertEqual(-90, LinkQuality.strongRssiDbm)
        XCTAssertEqual(3, LinkQuality.poorSnrDb)
        XCTAssertEqual(12, LinkQuality.elevatedFloorMarginDb)
        XCTAssertEqual(-100, LinkQuality.busyFloorDbm)
        XCTAssertEqual(-32768, LinkQuality.noiseFloorUnknown)
    }

    func testQuietChannelIsNormal() {
        XCTAssertEqual(.normal, LinkQuality.classify(
            rssi: -70, snr: 9, noiseFloor: -120, quietestFloor: -120))
    }

    /// Loud but dirty: power in the channel that is not our signal.
    func testLoudAndDirtyIsInterference() {
        XCTAssertEqual(.interference, LinkQuality.classify(
            rssi: -60, snr: 1, noiseFloor: -120, quietestFloor: -120))
    }

    /// Reported whether or not the floor corroborates — a burst interferer wrecks
    /// packets while the sampled floor still looks quiet, and that must not go
    /// unreported.
    func testLoudAndDirtyDoesNotNeedTheFloorToAgree() {
        XCTAssertEqual(.interference, LinkQuality.classify(
            rssi: -60, snr: 0, noiseFloor: unknown, quietestFloor: unknown))
    }

    /// **The apogee false alarm.** Low SNR at range is normal and must not fire: the
    /// packet is not loud, so poor SNR is adequately explained by distance.
    func testWeakAndDirtyIsNotInterference() {
        XCTAssertEqual(.normal, LinkQuality.classify(
            rssi: -115, snr: -5, noiseFloor: -120, quietestFloor: -120))
    }

    /// A packet that has aged out describes nothing. Re-asserting the last verdict is
    /// how a link that simply stopped got reported as being jammed.
    func testStalePacketCannotBeDegraded() {
        XCTAssertEqual(.normal, LinkQuality.classify(
            rssi: -60, snr: 0, noiseFloor: -120, quietestFloor: -120, packetFresh: false))
    }

    func testFloorRisenAboveBaselineIsCongested() {
        XCTAssertEqual(.congested, LinkQuality.classify(
            rssi: -70, snr: 9, noiseFloor: -108, quietestFloor: -120))
    }

    func testRiseBelowTheMarginIsNormal() {
        XCTAssertEqual(.normal, LinkQuality.classify(
            rssi: -70, snr: 9, noiseFloor: -109, quietestFloor: -120))
    }

    /// The absolute test exists because the relative one has a hole: if the channel
    /// is already busy at startup — the normal case for someone investigating
    /// interference — the baseline absorbs the interferer and nothing looks elevated.
    func testAlreadyBusyAtStartupIsStillDetected() {
        XCTAssertEqual(.congested, LinkQuality.classify(
            rssi: -70, snr: 9, noiseFloor: -95, quietestFloor: -95))
    }

    /// Occupied AND costing us packets — the co-channel case, where survivors look
    /// perfect so `degraded` never fires while the locator visibly drops out.
    func testOccupiedAndLossyIsInterference() {
        XCTAssertEqual(.interference, LinkQuality.classify(
            rssi: -70, snr: 9, noiseFloor: -95, quietestFloor: -95, lossy: true))
    }

    /// The conjunction is what keeps it honest: loss alone is ambiguous, since a
    /// locator switched off or walked out of range also produces gaps — but a locator
    /// that went away does not raise the noise floor.
    func testLossAloneIsNotInterference() {
        XCTAssertEqual(.normal, LinkQuality.classify(
            rssi: -70, snr: 9, noiseFloor: -120, quietestFloor: -120, lossy: true))
    }

    /// **The decisive signal.** A foreign locator is not evidence OF occupancy, it IS
    /// occupancy — decoded, identified, unambiguous — and it outranks every
    /// RSSI-derived signal, which is the correction the ADR came to after four bench
    /// rounds of measurements that could not fire.
    func testForeignLocatorAloneIsOccupancy() {
        XCTAssertEqual(.congested, LinkQuality.classify(
            rssi: -70, snr: 9, noiseFloor: -120, quietestFloor: -120, foreignLocator: true))
    }

    func testForeignLocatorCostingPacketsIsInterference() {
        XCTAssertEqual(.interference, LinkQuality.classify(
            rssi: -70, snr: 9, noiseFloor: -120, quietestFloor: -120,
            lossy: true, foreignLocator: true))
    }

    // MARK: - The sentinel that poisoned the baseline

    /// `kNoiseFloorUnknown` is INT16_MIN and arrives as −32768. Treating it as a real
    /// reading latched the baseline onto it and made every subsequent floor look
    /// ~32000 dB elevated.
    func testUnknownFloorNeverBecomesTheBaseline() {
        XCTAssertEqual(-110, LinkQuality.updateQuietestFloor(current: -110, sample: unknown))
        XCTAssertEqual(-110, LinkQuality.updateQuietestFloor(current: unknown, sample: -110))
    }

    func testBaselineKeepsTheQuietest() {
        XCTAssertEqual(-120, LinkQuality.updateQuietestFloor(current: -110, sample: -120))
        XCTAssertEqual(-120, LinkQuality.updateQuietestFloor(current: -120, sample: -110))
    }

    func testUnknownFloorCannotMakeTheChannelLookOccupied() {
        XCTAssertEqual(.normal, LinkQuality.classify(
            rssi: -115, snr: 9, noiseFloor: unknown, quietestFloor: -120))
    }

    /// A stale floor describes an interval that has passed.
    func testStaleFloorIsNotUsed() {
        XCTAssertEqual(.normal, LinkQuality.classify(
            rssi: -115, snr: 9, noiseFloor: -95, quietestFloor: -120, floorFresh: false))
    }
}
