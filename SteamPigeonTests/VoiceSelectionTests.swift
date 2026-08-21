import XCTest
import AVFoundation
@testable import SteamPigeon

/// Which voices are offered.
///
/// Reported from the phone: the list included Bubbles and Bells. Android never has to
/// filter — its engine offers no novelty voices — so this is an iOS-only rule, and the
/// list is what the user picks from, so it is the place to draw it.
final class VoiceSelectionTests: XCTestCase {

    /// The list Apple classes as novelty, enumerated FROM THE DEVICE rather than
    /// written from memory.
    private let knownNovelty = [
        "com.apple.speech.synthesis.voice.Bubbles",
        "com.apple.speech.synthesis.voice.Bells",
        "com.apple.speech.synthesis.voice.Zarvox",
        "com.apple.speech.synthesis.voice.Boing",
        "com.apple.speech.synthesis.voice.Albert",
    ]

    /// Voices that share the legacy identifier prefix and are NOT novelty. The
    /// tempting shortcut — exclude everything under
    /// `com.apple.speech.synthesis.voice.` — would quietly remove these four.
    private let legacyButNotNovelty = [
        "com.apple.speech.synthesis.voice.Fred",
        "com.apple.speech.synthesis.voice.Junior",
        "com.apple.speech.synthesis.voice.Kathy",
        "com.apple.speech.synthesis.voice.Ralph",
    ]

    private func voice(_ id: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: id)
    }

    func testNoveltyVoicesAreExcluded() {
        let offered = Set(AppSettings.availableVoices().map(\.identifier))
        for id in knownNovelty where voice(id) != nil {
            XCTAssertFalse(offered.contains(id), "\(id) is a novelty voice and was offered")
        }
    }

    /// The other half of the rule, and the one a prefix filter would break.
    func testLegacyNonNoveltyVoicesSurvive() {
        for id in legacyButNotNovelty {
            guard let v = voice(id) else { continue }
            XCTAssertFalse(AppSettings.isNovelty(v),
                           "\(id) is not a novelty voice and must stay in the list")
        }
    }

    /// Android filters to English and sorts by name; that part is unchanged.
    func testOfferedVoicesAreEnglishAndSortedByName() {
        let offered = AppSettings.availableVoices()
        for v in offered {
            XCTAssertTrue(v.language.hasPrefix("en"), "\(v.name) is \(v.language)")
        }
        XCTAssertEqual(offered.map(\.name), offered.map(\.name).sorted())
    }

    /// A device with voices must still offer some after filtering — a rule that
    /// removed everything would be worse than none.
    func testFilteringDoesNotEmptyTheList() throws {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        guard !english.isEmpty else { throw XCTSkip("no English voices on this device") }
        XCTAssertFalse(AppSettings.availableVoices().isEmpty)
    }
}
