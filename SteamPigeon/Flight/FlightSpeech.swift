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

    /// Called with every line that actually reaches the synthesizer, so the App Flight Log
    /// can hold what was said and when (ADR-0030).
    ///
    /// **This is where Android needed an `Announcer` facade and iOS does not.** There, some
    /// nineteen sites called `TextToSpeech.speak` directly, and a logging rule that has to
    /// be remembered at each is one that will be missed at the next one added; the facade
    /// exists to funnel them. `say` was already that funnel here — including the
    /// voice-enabled check — so the hook sits inside it and every present and future callout
    /// is carried by construction.
    ///
    /// Fires only when speech genuinely went out. With voice switched off nothing is spoken
    /// and nothing is recorded: the log is a record of what the operator heard, not of what
    /// the app would have said, and an entry for a callout nobody heard would put a cause in
    /// the timeline for a reaction that never happened.
    var onSpoken: ((String) -> Void)?

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
        onSpoken?(text)
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
