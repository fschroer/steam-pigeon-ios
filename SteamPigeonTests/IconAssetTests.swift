import XCTest
import UIKit
@testable import SteamPigeon

/// The app's own iconography, converted from Android's VectorDrawables.
///
/// Same failure shape as the fonts: a missing asset does not throw, it yields nil (or
/// a blank image), and a blank glyph in a corner reads as a layout quirk rather than a
/// missing file. These assert the conversion actually produced usable images.
final class IconAssetTests: XCTestCase {

    /// Every drawable the Android app references by name.
    private let expected = [
        "bomb", "broadcast", "compass", "flight_log", "ic_view_2d", "ic_view_3d",
        "navigation", "radio", "rocket", "rocket_md", "settings_applications",
        "u_turn_right",
    ]

    func testEveryAndroidIconConverted() {
        for name in expected {
            XCTAssertNotNil(UIImage(named: name), "\(name) missing from the asset catalog")
        }
    }

    /// A vector asset that lost its vector representation rasterises at one size and
    /// blurs everywhere else — the reason for converting rather than exporting PNGs.
    func testIconsHaveNonZeroSize() throws {
        for name in expected {
            let image = try XCTUnwrap(UIImage(named: name), name)
            XCTAssertGreaterThan(image.size.width, 0, "\(name) has zero width")
            XCTAssertGreaterThan(image.size.height, 0, "\(name) has zero height")
        }
    }

    /// Single-colour glyphs must be TEMPLATE images so they can be tinted, the way
    /// Android tints its `Icon(painter, tint = …)`. The rocket marker's whole trust
    /// signal is its colour, so a non-template asset would silently ignore the tint
    /// and always draw grey.
    func testSingleColourGlyphsAreTemplates() throws {
        for name in ["radio", "rocket_md", "navigation", "bomb", "u_turn_right",
                     "settings_applications", "broadcast", "flight_log"] {
            let image = try XCTUnwrap(UIImage(named: name), name)
            XCTAssertEqual(.alwaysTemplate, image.renderingMode,
                           "\(name) must be a template image to accept a tint")
        }
    }

    /// Multi-colour illustrations must NOT be templates — flattening them to a single
    /// tint would destroy the artwork.
    func testMultiColourIllustrationsStayOriginal() throws {
        for name in ["rocket", "compass", "ic_view_2d", "ic_view_3d"] {
            let image = try XCTUnwrap(UIImage(named: name), name)
            XCTAssertNotEqual(.alwaysTemplate, image.renderingMode,
                              "\(name) is multi-colour and must keep its own colours")
        }
    }
}
