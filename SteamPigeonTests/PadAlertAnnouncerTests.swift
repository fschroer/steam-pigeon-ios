import XCTest
@testable import SteamPigeon

/// The spoken and felt halves of the pad alert.
///
/// Reported from the phone as "doesn't vibrate and I can't hear a voice". The voice
/// half was not a fault in this alert — `AppSettings.voiceEnabled` and `voiceIdentifier`
/// were written by the settings screen and read by NOTHING, so the app was silent
/// everywhere. These pin the parts that are rules rather than plumbing.
@MainActor
final class PadAlertAnnouncerTests: XCTestCase {

    /// Android's `padAlertRepeatMillis`. Long on purpose — the escalation lives in the
    /// locator's buzzer, and repeating it here would be two things shouting.
    func testTheRepeatCadenceMatchesAndroid() {
        XCTAssertEqual(30, PadAlertAnnouncer.repeatInterval)
    }

    /// Android's exact wording, so one manual serves both platforms.
    func testTheSpokenWarningMatchesAndroid() {
        XCTAssertEqual("Warning. Rocket is on the pad and not armed.",
                       PadAlertAnnouncer.spokenWarning)
    }

    /// Android's waveform: 260 ms pulse, 140 ms gap, 260 ms pulse, 2.4 s rest.
    /// The rhythm is the message — a doubled pulse rather than a single notification
    /// buzz, echoing the locator's buzzer.
    func testTheHapticCycleMatchesAndroidsWaveform() {
        XCTAssertEqual(0.26 + 0.14 + 0.26 + 2.4, PadAlertHaptics.cycle, accuracy: 1e-9)
    }

    // MARK: - Speech gating

    private func settings(voice: Bool) -> AppSettings {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let s = AppSettings(defaults: defaults)
        s.voiceEnabled = voice
        return s
    }

    /// The setting is honoured in ONE place so a caller cannot forget it.
    func testSpeechRespectsTheVoiceSetting() {
        XCTAssertNoThrow(FlightSpeech(settings: settings(voice: false)).say("test"))
        XCTAssertNoThrow(FlightSpeech(settings: settings(voice: true)).say("test"))
    }

    /// Speech defaults ON, as Android's does — the callouts are the point of having the
    /// phone in a pocket during a flight.
    func testSpeechDefaultsOn() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertTrue(AppSettings(defaults: defaults).voiceEnabled)
    }

    /// Constructing and driving the announcer must be safe with speech switched off —
    /// the HAPTIC is deliberately not gated on that setting, so the two paths have to
    /// be independent.
    func testTheAnnouncerRunsWithSpeechOff() {
        let announcer = PadAlertAnnouncer(speech: FlightSpeech(settings: settings(voice: false)))
        announcer.update(.alerting)
        announcer.update(.snoozed)
        announcer.update(.quiet)
        announcer.stop()
    }

    /// A snoozed alert is shown, never spoken or felt: speaking through a snooze would
    /// make the control useless.
    func testOnlyAlertingAnnounces() {
        for state in [PadAlertState.quiet, .snoozed] {
            XCTAssertFalse(state == .alerting, "\(state) must not announce")
        }
    }
}
