import Foundation
import AVFoundation

/// User preferences, persisted. Mirrors the Android app's `UserPreferences` fields
/// that the settings screen writes.
final class AppSettings: ObservableObject {

    /// Closest zoom AUTO-zoom will frame to. Pinch is NOT bound by it — the user can
    /// always look closer; this only governs what the map does on its own.
    static let zoomLimitMin = 18
    static let zoomLimitMax = 22
    static let zoomLimitDefault = 20

    /// A stored value, or the default, clamped either way. Mirrors Android's
    /// `resolveMapMaxZoom`: a stored value from another build must not escape the
    /// range this build offers, or the slider cannot represent its own setting.
    static func resolveMapMaxZoom(_ stored: Int?) -> Int {
        min(max(stored ?? zoomLimitDefault, zoomLimitMin), zoomLimitMax)
    }

    @Published var voiceEnabled: Bool {
        didSet { defaults.set(voiceEnabled, forKey: Keys.voiceEnabled) }
    }
    @Published var voiceIdentifier: String? {
        didSet { defaults.set(voiceIdentifier, forKey: Keys.voiceIdentifier) }
    }
    @Published var mapMaxZoom: Int {
        didSet { defaults.set(mapMaxZoom, forKey: Keys.mapMaxZoom) }
    }

    private enum Keys {
        static let voiceEnabled = "com.steampigeon.ios.voiceEnabled"
        static let voiceIdentifier = "com.steampigeon.ios.voiceIdentifier"
        static let mapMaxZoom = "com.steampigeon.ios.mapMaxZoom"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Speech defaults ON, as on Android: the callouts are the point of having the
        // phone in a pocket during a flight.
        self.voiceEnabled = defaults.object(forKey: Keys.voiceEnabled) as? Bool ?? true
        self.voiceIdentifier = defaults.string(forKey: Keys.voiceIdentifier)
        self.mapMaxZoom = Self.resolveMapMaxZoom(defaults.object(forKey: Keys.mapMaxZoom) as? Int)
    }

    /// English voices the device offers, sorted by name — Android filters to
    /// `locale.language == "en"` and sorts the same way.
    ///
    /// **Novelty voices are excluded, which Android has no need to do.** Its engine
    /// offers none; iOS ships Bubbles, Bells, Boing, Zarvox and a dozen more alongside
    /// the real ones, and a rocket's altitude read out by Bubbles is not a callout. The
    /// list is what the user picks from, so this is the place to draw it.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !isNovelty($0) }
            .sorted { $0.name < $1.name }
    }

    /// Identifiers of the novelty voices, for the iOS 16 path.
    ///
    /// Enumerated from the device rather than written from memory, and that mattered
    /// twice. **Names are not stable** — Jester ships as `…voice.Hysterical`, Superstar
    /// as `…voice.Princess`, Wobble as `…voice.Deranged` — so a name-based list breaks
    /// silently when Apple renames one. And the tempting shortcut of excluding the
    /// legacy `com.apple.speech.synthesis.voice.` prefix is **wrong**: Fred, Junior,
    /// Kathy and Ralph share it and Apple does not class them as novelty, so that rule
    /// would quietly remove four ordinary voices.
    private static let noveltyIdentifiers: Set<String> = [
        "com.apple.speech.synthesis.voice.Albert",
        "com.apple.speech.synthesis.voice.BadNews",
        "com.apple.speech.synthesis.voice.Bahh",
        "com.apple.speech.synthesis.voice.Bells",
        "com.apple.speech.synthesis.voice.Boing",
        "com.apple.speech.synthesis.voice.Bubbles",
        "com.apple.speech.synthesis.voice.Cellos",
        "com.apple.speech.synthesis.voice.Deranged",
        "com.apple.speech.synthesis.voice.GoodNews",
        "com.apple.speech.synthesis.voice.Hysterical",
        "com.apple.speech.synthesis.voice.Organ",
        "com.apple.speech.synthesis.voice.Princess",
        "com.apple.speech.synthesis.voice.Trinoids",
        "com.apple.speech.synthesis.voice.Whisper",
        "com.apple.speech.synthesis.voice.Zarvox",
    ]

    /// iOS 17 knows this itself; 16 does not, and 16.0 is the deployment target.
    ///
    /// The system trait is preferred where it exists so a voice added later is
    /// classified by Apple rather than by this list going stale.
    static func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if #available(iOS 17.0, *) {
            return voice.voiceTraits.contains(.isNoveltyVoice)
        }
        return noveltyIdentifiers.contains(voice.identifier)
    }

    /// The copy under the zoom slider.
    ///
    /// Deliberately promises nothing about steadiness. Android's used to say a lower
    /// setting held a steadier frame — describing the limit as the cure for
    /// GPS-error pumping, which it never was, since the swings happen at and below
    /// the limit where a limit has nothing to bind. The map ignores framing changes
    /// small enough to be two receivers disagreeing, at every setting, so this
    /// control is only about detail versus context.
    static func zoomDescription(for zoom: Int) -> String {
        let lead = "How far in the map follows the rocket on its own. You can always pinch closer. "
        if zoom >= zoomLimitMax {
            return lead + "Closest available — most detail, least ground around the rocket."
        }
        if zoom <= zoomLimitMin {
            return lead + "The map stops well back, keeping more ground in view; the last stretch is done by eye."
        }
        return lead + "Lower settings keep more ground around the rocket, at the cost of the closest levels of detail."
    }
}
