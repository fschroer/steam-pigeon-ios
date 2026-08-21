import Foundation
import AVFoundation

/// The app's voice.
///
/// **This did not exist before.** `AppSettings.voiceEnabled` and `voiceIdentifier` were
/// written by the settings screen and read by nothing, so the app was silent
/// everywhere — which is why a missing pad-alert callout looked like a fault in that
/// alert rather than the absence of the whole feature.
///
/// Android drives TTS through one `TextToSpeech` instance shared by the flight
/// announcer, the arm/disarm acknowledgement and the pad alert, with `QUEUE_FLUSH` used
/// to let an urgent line cut in front of a routine one. Same model here.
@MainActor
final class FlightSpeech: NSObject {

    /// Whether a line waits its turn or takes the floor.
    enum Priority {
        /// Queue behind whatever is speaking. Android's `QUEUE_ADD`.
        case routine
        /// Cut in. Android's `QUEUE_FLUSH` — used where the line outranks whatever
        /// routine callout is mid-sentence.
        case urgent
    }

    private let synthesizer = AVSpeechSynthesizer()
    private weak var settings: AppSettings?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        configureAudioSession()
    }

    /// **`.playback`, deliberately.**
    ///
    /// The default `.ambient`/`.soloAmbient` category obeys the ring/silent switch, so
    /// on a phone with the switch flipped — which is most phones at a launch — every
    /// callout would be generated, mixed and then thrown away, with nothing to show for
    /// it. Android's TTS goes out on `STREAM_MUSIC`, which the ringer mute does not
    /// touch, so obeying the switch here would also be a platform divergence in the one
    /// direction that matters: silent when it should be talking.
    ///
    /// `.duckOthers` rather than interrupting, so someone's music drops under the
    /// callout instead of stopping. `.mixWithOthers` keeps navigation and calls alive.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.duckOthers, .mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // Non-fatal on purpose: a phone that refuses the category still shows every
            // banner and still vibrates. Losing the voice must not cost the screen.
        }
    }

    /// Speak, if speech is switched on.
    ///
    /// The setting is checked HERE rather than at each call site, so a caller cannot
    /// forget it — and so the pad-alert haptic, which is deliberately NOT gated on this
    /// setting, stays the obvious exception rather than one of two arbitrary policies.
    func say(_ text: String, priority: Priority = .routine) {
        guard settings?.voiceEnabled == true, !text.isEmpty else { return }
        if priority == .urgent, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        if let id = settings?.voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    /// Stop mid-sentence. Used when the condition being announced has gone away.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
