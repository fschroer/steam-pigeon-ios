import XCTest
import UIKit
import SwiftUI
@testable import SteamPigeon

/// The theme is a **shared asset** with Android per ADR-0016's 2026-08-19
/// clarification, so these check it actually matches rather than approximately does.
final class ThemeTests: XCTestCase {

    /// The failure this exists for: an unbundled font falls back to the system face
    /// **silently**. Nothing errors, nothing logs, and the result looks like a design
    /// choice rather than a missing file — so it survives review.
    func testEveryFontIsRegisteredWithTheOS() {
        for name in SPFont.registeredNames {
            XCTAssertNotNil(UIFont(name: name, size: 12),
                            "\(name) is not registered — check UIAppFonts and the PostScript name, "
                            + "which is NOT the filename")
        }
    }

    /// PostScript names, not filenames. `poppins_regular.ttf` registers as
    /// `Poppins-Regular`, and using the filename yields a silent fallback.
    func testPostScriptNamesAreTheOnesAndroidUses() {
        XCTAssertNotNil(UIFont(name: "Poppins-Regular", size: 12))
        XCTAssertNotNil(UIFont(name: "Poppins-Bold", size: 12))
        XCTAssertNotNil(UIFont(name: "Roboto-Regular", size: 12))
        XCTAssertNotNil(UIFont(name: "Roboto-Bold", size: 12))
        XCTAssertNotNil(UIFont(name: "RobotoMono-Regular", size: 12))
        XCTAssertNotNil(UIFont(name: "RobotoMono-Bold", size: 12))
    }

    /// A mono face must actually be monospaced, or telemetry digits will not hold a
    /// column as values change — the whole reason Android has a separate family.
    func testTelemetryFaceIsMonospaced() throws {
        let font = try XCTUnwrap(UIFont(name: "RobotoMono-Regular", size: 14))
        let narrow = ("1" as NSString).size(withAttributes: [.font: font]).width
        let wide = ("W" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(narrow, wide, accuracy: 0.01, "RobotoMono is not advancing uniformly")
    }

    /// Spot-check the palette against `ui/theme/Color.kt`. Values, not vibes: these are
    /// the same hex numbers, and a drift means the two apps stop looking like one.
    func testPaletteMatchesTheAndroidDarkScheme() {
        assertColor(SPColor.background, 0x14, 0x13, 0x12, "backgroundDark")
        assertColor(SPColor.onBackground, 0xE6, 0xE2, 0xDF, "onBackgroundDark")
        assertColor(SPColor.primary, 0xCC, 0xC6, 0xB7, "primaryDark")
        assertColor(SPColor.secondary, 0xB4, 0xC6, 0xF2, "secondaryDark")
        assertColor(SPColor.tertiary, 0xDC, 0xC4, 0x8D, "tertiaryDark")
        assertColor(SPColor.error, 0xFF, 0xB4, 0xAB, "errorDark")
        assertColor(SPColor.outline, 0x95, 0x90, 0x87, "outlineDark")
        assertColor(SPColor.surfaceContainer, 0x20, 0x1F, 0x1E, "surfaceContainerDark")
    }

    private func assertColor(_ color: Color, _ r: Int, _ g: Int, _ b: Int, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        UIColor(color).getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        XCTAssertEqual(Int((rr * 255).rounded()), r, "\(label) red", file: file, line: line)
        XCTAssertEqual(Int((gg * 255).rounded()), g, "\(label) green", file: file, line: line)
        XCTAssertEqual(Int((bb * 255).rounded()), b, "\(label) blue", file: file, line: line)
    }

    /// The hex initialiser is the thing every colour above depends on.
    func testHexInitialiserIsCorrect() {
        assertColor(Color(hex: 0x000000), 0, 0, 0, "black")
        assertColor(Color(hex: 0xFFFFFF), 255, 255, 255, "white")
        assertColor(Color(hex: 0xFF8000), 255, 128, 0, "orange")
    }
}
