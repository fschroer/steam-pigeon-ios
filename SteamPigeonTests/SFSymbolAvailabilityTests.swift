import XCTest
import UIKit
@testable import SteamPigeon

/// The SF Symbols standing in for Android's Compose `Icons.Default.*`.
///
/// Android's control-column icons come from the Material icons LIBRARY, not from
/// drawables in the repo, so there is nothing for `Tools/vd2svg.py` to convert and
/// these are chosen substitutes. Two ways that goes wrong, and this covers one and a
/// half of them:
///
/// 1. **A typo, or a symbol that does not exist at all.** `Image(systemName:)` renders
///    nothing and says nothing. Caught here.
/// 2. **A symbol that exists but was added after iOS 16.0**, the deployment target. It
///    renders on any simulator this Mac can run (only iOS 26.5 runtimes are installed)
///    and is a blank box on any phone older than the symbol. **A test cannot catch that
///    here** — the simulator is too new to disagree.
///
///    The app is flown across **multiple iOS versions**, so the floor is what governs:
///    a symbol added after 16.0 is fine on the newer phones and blank on the oldest, and
///    the newer ones cannot vouch for it. Check every name against the availability data
///    below rather than against whichever device is in hand.
///
/// So the iOS-16 floor was checked against the system's own availability data instead,
/// on 2026-08-20, and every name below came back iOS 13.0–15.0. Re-run when changing a
/// symbol:
///
/// ```
/// plutil -p "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/\
/// Resources/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
/// ```
///
/// The `symbols` dict maps each name to a year key; `year_to_release` maps that year
/// to the iOS version. Anything above 16.0 is unusable.
final class SFSymbolAvailabilityTests: XCTestCase {

    /// name → the iOS version it became available in, as verified above.
    private let symbols: [String: String] = [
        "scope":                             "13.0",   // Android MyLocation
        "arrow.up.left.and.arrow.down.right": "13.0",  // Android ZoomOutMap
        "safari":                            "13.0",   // Android Explore
        "rotate.3d":                         "14.0",   // Android ScreenRotation
        "circle.fill":                       "13.0",   // Android FiberManualRecord
        "stop.fill":                         "13.0",   // Android Stop
        "arrow.counterclockwise":            "13.0",   // Android RestartAlt
        "line.3.horizontal":                 "13.0",   // Android Menu
        "stethoscope":                       "14.0",   // no Android counterpart
        "trash":                             "13.0",   // Android Icons.Filled.Delete
        "info.circle":                       "13.0",   // Android Icons.Default.Info
        "chevron.down":                      "13.0",   // Android ExposedDropdownMenu chevron
        // Added 2026-09-02 with the archived-path control, and it should have been added
        // with it: the map's history button shipped without passing through this list,
        // which is the one check that stands between a mistyped name and a button that
        // renders nothing and says nothing. Verified 14.0 against the availability plist
        // named above, so it is safe at the 16.0 floor.
        "clock.arrow.circlepath":            "14.0",   // Android Icons.Default.History
    ]

    func testEverySymbolResolves() {
        for name in symbols.keys {
            XCTAssertNotNil(UIImage(systemName: name),
                            "\(name) is not an SF Symbol — check the spelling")
        }
    }

    /// The recorded floor is what makes the names safe to use; if one is ever raised
    /// above the deployment target the note above stops being true.
    func testNoSymbolNeedsMoreThanTheDeploymentTarget() {
        for (name, since) in symbols {
            let major = Int(since.split(separator: ".")[0]) ?? .max
            XCTAssertLessThanOrEqual(major, 16, "\(name) needs iOS \(since), above the 16.0 target")
        }
    }
}
