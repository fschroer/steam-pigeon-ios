import Foundation
import Combine

/// Holds the voice and the pad-alert announcer for the screen that owns them.
///
/// A tiny `ObservableObject` wrapper so SwiftUI keeps ONE `AVSpeechSynthesizer` and one
/// haptic engine per screen rather than rebuilding them on every body evaluation.
/// Building a synthesiser is not free, and rebuilding one mid-sentence cuts it off.
@MainActor
final class SpeechCoordinator: ObservableObject {
    let speech: FlightSpeech
    let padAlert: PadAlertAnnouncer

    init(settings: AppSettings) {
        let speech = FlightSpeech(settings: settings)
        self.speech = speech
        self.padAlert = PadAlertAnnouncer(speech: speech)
    }
}
