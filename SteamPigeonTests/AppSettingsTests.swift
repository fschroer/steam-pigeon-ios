import XCTest
@testable import SteamPigeon

final class AppSettingsTests: XCTestCase {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testZoomLimitsMatchAndroid() {
        XCTAssertEqual(18, AppSettings.zoomLimitMin)
        XCTAssertEqual(22, AppSettings.zoomLimitMax)
        XCTAssertEqual(20, AppSettings.zoomLimitDefault)
    }

    func testUnsetZoomResolvesToTheDefault() {
        XCTAssertEqual(20, AppSettings.resolveMapMaxZoom(nil))
    }

    /// A value stored by another build must not escape the range this build offers,
    /// or the slider cannot represent its own setting.
    func testStoredZoomIsClampedToTheOfferedRange() {
        XCTAssertEqual(18, AppSettings.resolveMapMaxZoom(3))
        XCTAssertEqual(22, AppSettings.resolveMapMaxZoom(99))
        XCTAssertEqual(19, AppSettings.resolveMapMaxZoom(19))
    }

    /// Speech defaults ON — the callouts are the point of having the phone pocketed
    /// during a flight, so an unset preference must not mean silence.
    func testSpeechDefaultsOn() {
        let suite = "test.settings.\(UUID().uuidString)"
        let d = freshDefaults(suite)
        XCTAssertTrue(AppSettings(defaults: d).voiceEnabled)
        d.removePersistentDomain(forName: suite)
    }

    func testSettingsSurviveARelaunch() {
        let suite = "test.settings.\(UUID().uuidString)"
        let d = freshDefaults(suite)
        let first = AppSettings(defaults: d)
        first.voiceEnabled = false
        first.mapMaxZoom = 19
        first.voiceIdentifier = "com.apple.voice.test"

        let reloaded = AppSettings(defaults: d)
        XCTAssertFalse(reloaded.voiceEnabled)
        XCTAssertEqual(19, reloaded.mapMaxZoom)
        XCTAssertEqual("com.apple.voice.test", reloaded.voiceIdentifier)
        d.removePersistentDomain(forName: suite)
    }

    /// The copy must not promise steadiness. Android's used to describe the limit as
    /// the cure for GPS-error pumping, which it never was — the swings happen at and
    /// below the limit, where a limit has nothing to bind.
    func testZoomCopyDescribesDetailVersusContextOnly() {
        for z in AppSettings.zoomLimitMin...AppSettings.zoomLimitMax {
            let text = AppSettings.zoomDescription(for: z)
            XCTAssertTrue(text.contains("You can always pinch closer"))
            XCTAssertFalse(text.lowercased().contains("steady"))
            XCTAssertFalse(text.lowercased().contains("jump"))
        }
    }

    func testZoomCopyDistinguishesTheEnds() {
        let closest = AppSettings.zoomDescription(for: AppSettings.zoomLimitMax)
        let widest = AppSettings.zoomDescription(for: AppSettings.zoomLimitMin)
        let middle = AppSettings.zoomDescription(for: 20)
        XCTAssertTrue(closest.contains("Closest available"))
        XCTAssertTrue(widest.contains("stops well back"))
        XCTAssertNotEqual(closest, middle)
        XCTAssertNotEqual(widest, middle)
    }
}
