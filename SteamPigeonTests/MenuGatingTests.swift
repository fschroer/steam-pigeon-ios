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

    /// With nothing connected there are still three entries: app settings, map download
    /// — which is done at home, precisely when nothing is connected — and the app flight
    /// logs, which are files on the phone and are read with the receiver switched off.
    func testNothingConnectedStillOffersSettingsMapDownloadAndLogs() {
        XCTAssertEqual([.appSettings, .downloadMap, .appFlightLogs],
                       menu(linkReady: false, locatorActive: false))
    }

    /// Communication needs the receiver, not a locator — it is the screen you open
    /// BECAUSE no locator is being heard, so gating it on one would hide it in the only
    /// state it is for.
    func testCommunicationNeedsTheLinkAndNotALocator() {
        XCTAssertFalse(menu(linkReady: false, locatorActive: false).contains(.communication))
        XCTAssertTrue(menu(linkReady: true, locatorActive: false).contains(.communication))
        XCTAssertEqual(.communication, menu(linkReady: true, locatorActive: false).first)
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

    /// Application Settings and Download maps are always offered, whatever is connected:
    /// neither needs hardware, and map download is done at home precisely when nothing
    /// is.
    func testSettingsAndMapDownloadAreAlwaysOffered() {
        for ready in [true, false] {
            for active in [true, false] {
                for armed in [true, false] {
                    let items = MenuGating.destinations(linkReady: ready,
                                                        locatorActive: active, armed: armed)
                    XCTAssertTrue(items.contains(.appSettings))
                    XCTAssertTrue(items.contains(.downloadMap))
                }
            }
        }
    }

    /// Android's order after ADR-0029 and ADR-0030: Communication, Flight Profiles,
    /// Locator Settings, Receiver Settings, Application Settings, Download maps, App
    /// Flight Logs, Deployment Test. **Flight Profiles above Locator Settings**, which is
    /// the pair that swapped.
    func testFullyConnectedDisarmedOrderMatchesAndroid() {
        XCTAssertEqual([.communication, .flightProfiles, .locatorSettings,
                        .receiverSettings, .appSettings, .downloadMap, .appFlightLogs],
                       menu(linkReady: true, locatorActive: true, armed: false))
    }

    /// App Flight Logs is **ungated**, and that is the point of it: a log is read after
    /// the flight, at home, with the receiver in a bag. Gating it on the link would hide
    /// it in exactly the state it is wanted.
    func testAppFlightLogsIsAlwaysOffered() {
        for ready in [true, false] {
            for active in [true, false] {
                for armed in [true, false] {
                    XCTAssertTrue(
                        menu(linkReady: ready, locatorActive: active, armed: armed)
                            .contains(.appFlightLogs),
                        "ready=\(ready) active=\(active) armed=\(armed)")
                }
            }
        }
    }

    /// Deployment Test is last, not third: it is armed-only, so it never shares the list
    /// with the disarmed entries, and the rarest and most consequential entry sits
    /// furthest from a thumb.
    func testFullyConnectedArmedOrderMatchesAndroid() {
        XCTAssertEqual([.communication, .receiverSettings, .appSettings,
                        .downloadMap, .appFlightLogs, .deploymentTest],
                       menu(linkReady: true, locatorActive: true, armed: true))
    }
}
