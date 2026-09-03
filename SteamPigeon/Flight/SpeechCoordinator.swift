import Foundation
import Combine

/// Holds the voice and the pad-alert announcer.
///
/// A tiny `ObservableObject` wrapper so SwiftUI keeps ONE `AVSpeechSynthesizer` and one
/// haptic engine rather than rebuilding them on every body evaluation.
///
/// **Owned by `RootView`, not by the map screen.** Android calls `FlightSpeechAnnouncer`
/// from `HomeScreen` *outside* the orientation branch, so it announces in landscape as
/// well — while this sat on `MapScreen`, turning the phone sideways took the announcer,
/// the pad alert and its haptic away entirely, and turning it back built a synthesiser and
/// activated an audio session on the main thread again.
/// Building a synthesiser is not free, and rebuilding one mid-sentence cuts it off.
@MainActor
final class SpeechCoordinator: ObservableObject {
    let speech: FlightSpeech
    let padAlert: PadAlertAnnouncer
    /// The flight callouts — apogee, charges, altitudes, descent, landing, link and GPS.
    let flight: FlightAnnouncerRunner

    init(settings: AppSettings? = nil) {
        let speech = FlightSpeech(settings: settings)
        self.speech = speech
        self.padAlert = PadAlertAnnouncer(speech: speech)
        self.flight = FlightAnnouncerRunner(speech: speech)
    }

    /// Hand the voice the settings it reads. See `FlightSpeech.settings` for why this is
    /// not an init parameter at the call site that matters.
    func attach(_ settings: AppSettings) { speech.settings = settings }
}
