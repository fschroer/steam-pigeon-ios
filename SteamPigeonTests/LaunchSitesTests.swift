import CoreLocation
import XCTest
@testable import SteamPigeon

/// The launch-site CSV, the coordinate box, and the geometry that turns a centre point
/// into a region.
///
/// The CSV is **user-editable** — that is the whole point of it — so its parser is the
/// one place in this app where the input is written by hand at a kitchen table the night
/// before a launch. Every rule below exists because a plausible line would otherwise be
/// silently dropped.
final class LaunchSitesTests: XCTestCase {

    // MARK: - CSV

    func testFullLineWithBothExtents() throws {
        let site = try XCTUnwrap(LaunchSiteRepository.parseLine("Pad,47.5,-122.25,12,8"))
        XCTAssertEqual(site.name, "Pad")
        XCTAssertEqual(site.lat, 47.5, accuracy: 1e-9)
        XCTAssertEqual(site.lon, -122.25, accuracy: 1e-9)
        XCTAssertEqual(site.widthKm, 12, accuracy: 1e-9)
        XCTAssertEqual(site.heightKm, 8, accuracy: 1e-9)
    }

    /// One extent means a square, and no extent means the default — writing just
    /// `name,lat,lon` is the obvious thing to do and must not drop the line.
    func testExtentsAreOptional() throws {
        let square = try XCTUnwrap(LaunchSiteRepository.parseLine("Pad,47.5,-122.25,6"))
        XCTAssertEqual(square.widthKm, 6, accuracy: 1e-9)
        XCTAssertEqual(square.heightKm, 6, accuracy: 1e-9)

        let bare = try XCTUnwrap(LaunchSiteRepository.parseLine("Pad,47.5,-122.25"))
        XCTAssertEqual(bare.widthKm, LaunchSiteRepository.defaultExtentKm, accuracy: 1e-9)
        XCTAssertEqual(bare.heightKm, LaunchSiteRepository.defaultExtentKm, accuracy: 1e-9)
    }

    /// The trailing numeric fields are the values, so a name may contain commas — which
    /// nearly every real site name does: "Black Rock, NV".
    func testNameMayContainCommas() throws {
        let site = try XCTUnwrap(
            LaunchSiteRepository.parseLine("BALLS Black Rock, NV,40.844967,-119.11217,20,20"))
        XCTAssertEqual(site.name, "BALLS Black Rock, NV")
        XCTAssertEqual(site.lat, 40.844967, accuracy: 1e-9)
        XCTAssertEqual(site.widthKm, 20, accuracy: 1e-9)
    }

    func testRejectsLinesThatCannotBeASite() {
        XCTAssertNil(LaunchSiteRepository.parseLine("Pad,47.5"), "no longitude")
        XCTAssertNil(LaunchSiteRepository.parseLine("47.5,-122.25"), "no name")
        XCTAssertNil(LaunchSiteRepository.parseLine("Pad,north,-122.25"), "unparseable latitude")
        XCTAssertNil(LaunchSiteRepository.parseLine("Pad,95,-122.25"), "latitude out of range")
        XCTAssertNil(LaunchSiteRepository.parseLine("Pad,47.5,-200"), "longitude out of range")
        XCTAssertNil(LaunchSiteRepository.parseLine("Pad,47.5,-122.25,0"), "zero extent")
        XCTAssertNil(LaunchSiteRepository.parseLine("Pad,47.5,-122.25,-5"), "negative extent")
    }

    /// Comments and blank lines are skipped, and one bad line does not fail the file.
    func testParseSkipsCommentsAndKeepsGoingPastABadLine() {
        let sites = LaunchSiteRepository.parse("""
            # a comment

            Good,47.5,-122.25,10,10
            broken line with no numbers
            Also Good,40.0,-119.0
            """)
        XCTAssertEqual(sites.map(\.name), ["Good", "Also Good"])
    }

    /// The bundled template has to survive its own parser — it is what a user edits, so
    /// a typo in it would ship as "no preset sites".
    func testBundledTemplateParses() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "launch_sites",
                                                           withExtension: "csv")
            ?? Bundle.main.url(forResource: "launch_sites", withExtension: "csv"))
        let sites = LaunchSiteRepository.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(sites.count, 4)
        XCTAssertEqual(sites.first?.name, "WAC 60 Acres Redmond, WA")
        XCTAssertEqual(try XCTUnwrap(sites.last).widthKm, 20, accuracy: 1e-9)
    }

    // MARK: - Coordinate entry

    func testParsesCommaAndSpaceSeparatedPairs() throws {
        for text in ["47.6205, -122.5490", "47.6205,-122.5490", "47.6205 -122.5490"] {
            let p = try XCTUnwrap(parseLatLon(text), text)
            XCTAssertEqual(p.latitude, 47.6205, accuracy: 1e-9)
            XCTAssertEqual(p.longitude, -122.5490, accuracy: 1e-9)
        }
    }

    func testRejectsPairsThatAreNotCoordinates() {
        XCTAssertNil(parseLatLon(""))
        XCTAssertNil(parseLatLon("47.6205"))
        XCTAssertNil(parseLatLon("47.6205, -122.5490, 100"))
        XCTAssertNil(parseLatLon("north, west"))
        XCTAssertNil(parseLatLon("91, 0"))
        XCTAssertNil(parseLatLon("0, 181"))
    }

    /// The readout must feed its own parser — the box is both, and a format the parser
    /// rejected would make the Go button dead on a coordinate the user never typed.
    func testFormatRoundTripsThroughParse() throws {
        let p = CLLocationCoordinate2D(latitude: -43.8007, longitude: 120.6498)
        let back = try XCTUnwrap(parseLatLon(formatLatLon(p)))
        XCTAssertEqual(back.latitude, p.latitude, accuracy: 1e-4)
        XCTAssertEqual(back.longitude, p.longitude, accuracy: 1e-4)
    }

    // MARK: - Geometry

    func testBoundsAroundIsCentredAndTheRequestedSize() {
        let b = boundsAround(lat: 47.5, lon: -122.25, widthKm: 10, heightKm: 20)
        XCTAssertEqual(b.center.latitude, 47.5, accuracy: 1e-6)
        XCTAssertEqual(b.center.longitude, -122.25, accuracy: 1e-6)

        let (w, h) = b.groundSizeKm
        XCTAssertEqual(w, 10, accuracy: 0.05)
        XCTAssertEqual(h, 20, accuracy: 0.05)
    }

    /// Longitude degrees shrink with latitude, so a box of a given width in km spans
    /// more degrees the further north it sits. Getting this backwards would size polar
    /// regions wildly wrong.
    func testWidthInDegreesGrowsWithLatitude() {
        let equator = boundsAround(lat: 0, lon: 0, widthKm: 10, heightKm: 10)
        let far = boundsAround(lat: 60, lon: 0, widthKm: 10, heightKm: 10)
        XCTAssertGreaterThan(far.east - far.west, (equator.east - equator.west) * 1.9)
        // …but the ground size is still the size that was asked for.
        XCTAssertEqual(far.groundSizeKm.width, 10, accuracy: 0.05)
    }

    /// The cos term is guarded, so a site near the pole produces a usable box instead of
    /// a division by zero.
    func testNearThePoleTheBoxStaysFinite() {
        let b = boundsAround(lat: 89.9, lon: 0, widthKm: 10, heightKm: 10)
        XCTAssertTrue(b.north.isFinite && b.south.isFinite && b.east.isFinite && b.west.isFinite)
        XCTAssertLessThanOrEqual(b.north, 85)
    }
}
