import XCTest
@testable import SteamPigeon

/// Menu gating, mirroring Android's `AppDrawerContent`.
///
/// The rules are not guessable, which is why they are tested rather than eyeballed:
/// two of the six entries appear only while ARMED or only while DISARMED, and getting
/// either backwards offers a control the locator will refuse.
final class MenuGatingTests: XCTestCase {

    private func menu(linkReady: Bool = true, locatorActive: Bool = true,
                      armed: Bool = false) -> [MenuDestination] {
        MenuGating.destinations(linkReady: linkReady, locatorActive: locatorActive, armed: armed)
    }

    /// With nothing connected there are still two entries: app settings, and map
    /// download — which is done at home, precisely when nothing is connected.
    func testNothingConnectedStillOffersSettingsAndMapDownload() {
        XCTAssertEqual([.appSettings, .downloadMap],
                       menu(linkReady: false, locatorActive: false))
    }

    func testReceiverSettingsNeedTheLink() {
        XCTAssertFalse(menu(linkReady: false, locatorActive: false).contains(.receiverSettings))
        XCTAssertTrue(menu(linkReady: true, locatorActive: false).contains(.receiverSettings))
    }

    /// Locator settings and flight profiles are DISARMED-only: the locator refuses
    /// configuration changes in any other state, so offering them would be a control
    /// that silently does nothing.
    func testLocatorConfigurationIsDisarmedOnly() {
        let disarmed = menu(armed: false)
        XCTAssertTrue(disarmed.contains(.locatorSettings))
        XCTAssertTrue(disarmed.contains(.flightProfiles))

        let armed = menu(armed: true)
        XCTAssertFalse(armed.contains(.locatorSettings))
        XCTAssertFalse(armed.contains(.flightProfiles))
    }

    /// Deployment test is ARMED-only, which reads backwards until you notice that
    /// firing a deployment channel is exactly what arming enables.
    func testDeploymentTestIsArmedOnly() {
        XCTAssertFalse(menu(armed: false).contains(.deploymentTest))
        XCTAssertTrue(menu(armed: true).contains(.deploymentTest))
    }

    /// Neither locator entry appears without a locator, whatever the armed flag says.
    func testNoLocatorMeansNoLocatorEntries() {
        for armed in [true, false] {
            let items = menu(locatorActive: false, armed: armed)
            XCTAssertFalse(items.contains(.locatorSettings))
            XCTAssertFalse(items.contains(.flightProfiles))
            XCTAssertFalse(items.contains(.deploymentTest))
        }
    }

    /// Map download is LAST on purpose — site prep is done at home, not reached for
    /// at the pad, so it sits below the entries tracking what is connected now.
    func testMapDownloadIsAlwaysLast() {
        for ready in [true, false] {
            for active in [true, false] {
                for armed in [true, false] {
                    let items = MenuGating.destinations(linkReady: ready,
                                                        locatorActive: active, armed: armed)
                    XCTAssertEqual(.downloadMap, items.last)
                    XCTAssertEqual(.appSettings, items.first)
                }
            }
        }
    }

    func testFullyConnectedDisarmedOrderMatchesAndroid() {
        XCTAssertEqual([.appSettings, .receiverSettings, .locatorSettings,
                        .flightProfiles, .downloadMap],
                       menu(linkReady: true, locatorActive: true, armed: false))
    }

    func testFullyConnectedArmedOrderMatchesAndroid() {
        XCTAssertEqual([.appSettings, .receiverSettings, .deploymentTest, .downloadMap],
                       menu(linkReady: true, locatorActive: true, armed: true))
    }
}
