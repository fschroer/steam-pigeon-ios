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
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
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
