import XCTest
@testable import SteamPigeon

/// The tile count and storage estimate the download screen shows.
///
/// This number is the one the user decides on — "is this small enough to finish tonight
/// on hotel wi-fi?" — so being wrong by a factor is not cosmetic. It is also the one
/// piece of the offline path that can be checked without a network, a map view, or a
/// launch site.
final class TileMathTests: XCTestCase {

    /// Zoom 0 is one tile for the whole world, whatever the bounds.
    func testWholeWorldAtZoomZeroIsOneTile() {
        let world = GeoBounds(north: 80, south: -80, east: 179, west: -179)
        XCTAssertEqual(TileMath.tileCount(world, at: 0), 1)
    }

    /// Each level quarters the tile size, so a fixed box costs roughly 4× per level.
    /// This is why the estimate has to be summed per zoom and why the deepest level
    /// dominates the total.
    func testTileCountRoughlyQuadruplesPerZoomLevel() {
        let b = boundsAround(lat: 47.5, lon: -122.25, widthKm: 20, heightKm: 20)
        let counts = (12...17).map { TileMath.tileCount(b, at: $0) }
        for (shallow, deep) in zip(counts, counts.dropFirst()) {
            let ratio = Double(deep) / Double(shallow)
            // Not exactly 4: a box's edges land inside tiles, so the count is the
            // covering rectangle, which rounds up differently level to level.
            XCTAssertGreaterThan(ratio, 2.5)
            XCTAssertLessThan(ratio, 6.0)
        }
    }

    func testPyramidIsTheSumOfItsLevels() {
        let b = boundsAround(lat: 40.84, lon: -119.11, widthKm: 20, heightKm: 20)
        let summed = (10...17).reduce(0) { $0 + TileMath.tileCount(b, at: $1) }
        XCTAssertEqual(TileMath.tileCount(b, minZoom: 10, maxZoom: 17), summed)
    }

    /// The context pyramid below the chosen maximum is nearly free — the argument for
    /// always caching down to the provider's floor rather than to maxZoom − N.
    func testTheLevelsBelowTheMaximumCostAlmostNothing() {
        let b = boundsAround(lat: 47.5, lon: -122.25, widthKm: 10, heightKm: 10)
        let deepest = TileMath.tileCount(b, at: 17)
        let context = TileMath.tileCount(b, minZoom: 10, maxZoom: 16)
        XCTAssertLessThan(Double(context), Double(deepest) * 0.5)
    }

    func testEstimateUsesEachLevelsOwnTileSize() {
        let b = boundsAround(lat: 47.5, lon: -122.25, widthKm: 5, heightKm: 5)
        let expected = (10...20).reduce(0) {
            $0 + TileMath.tileCount(b, at: $1) * SatelliteProvider.mapbox.avgTileBytes($1)
        }
        XCTAssertEqual(TileMath.estimateBytes(b, minZoom: 10, maxZoom: 20, provider: .mapbox),
                       expected)
    }

    /// Mapbox's bytes-per-tile collapses past z19 because the imagery is upscaled there.
    /// A flat average would misprice the deepest level, which is most of the download.
    func testMapboxTileBytesCollapsePastNativeResolution() {
        XCTAssertGreaterThan(SatelliteProvider.mapbox.avgTileBytes(18),
                             SatelliteProvider.mapbox.avgTileBytes(20))
        XCTAssertGreaterThan(SatelliteProvider.mapbox.avgTileBytes(20),
                             SatelliteProvider.mapbox.avgTileBytes(22))
    }

    /// A reversed range is a degenerate call, not a whole-world download.
    func testInvertedZoomRangeCostsNothing() {
        let b = boundsAround(lat: 47.5, lon: -122.25, widthKm: 10, heightKm: 10)
        XCTAssertEqual(TileMath.tileCount(b, minZoom: 17, maxZoom: 10), 0)
        XCTAssertEqual(TileMath.estimateBytes(b, minZoom: 17, maxZoom: 10, provider: .esri), 0)
    }

    /// A real region, priced end to end: the number someone actually reads.
    func testATypicalLaunchSiteIsAPlausibleDownload() {
        let b = boundsAround(lat: 40.844967, lon: -119.11217, widthKm: 20, heightKm: 20)
        let bytes = TileMath.estimateBytes(b, minZoom: 10, maxZoom: 17, provider: .esri)
        // Tens of megabytes: big enough to want wi-fi, small enough to finish.
        XCTAssertGreaterThan(bytes, 10_000_000)
        XCTAssertLessThan(bytes, 300_000_000)
    }

    // MARK: - Presentation

    func testFormatBytesUsesDecimalUnits() {
        XCTAssertEqual(formatBytes(512), "512 B")
        XCTAssertEqual(formatBytes(2_400), "2 kB")
        XCTAssertEqual(formatBytes(45_000_000), "45 MB")
        XCTAssertEqual(formatBytes(1_500_000_000), "1.5 GB")
    }

    func testZoomHintNamesWhatEachLevelBuys() {
        XCTAssertEqual(zoomHint(17, provider: .esri), "Field features — good for recovery.")
        XCTAssertEqual(zoomHint(14, provider: .esri), "Regional context.")
        XCTAssertTrue(zoomHint(20, provider: .mapbox).contains("Mapbox"))
    }

    // MARK: - Providers

    /// Mapbox needs a token, and this build has none, so it is offered but not
    /// selectable — and the preference must not be able to strand the screen on it.
    func testMapboxIsUnavailableWithoutAToken() {
        XCTAssertTrue(SatelliteProvider.esri.isAvailable)
        XCTAssertEqual(SatelliteProvider.mapbox.isAvailable,
                       !SatelliteProvider.mapboxToken.isEmpty)

        let defaults = UserDefaults(suiteName: "TileMathTests")!
        defaults.removePersistentDomain(forName: "TileMathTests")
        MapProviderPrefs.set(.mapbox, defaults)
        if SatelliteProvider.mapbox.isAvailable {
            XCTAssertEqual(MapProviderPrefs.get(defaults), .mapbox)
        } else {
            XCTAssertEqual(MapProviderPrefs.get(defaults), .esri,
                           "an unavailable stored provider must fall back")
        }
    }

    /// The Esri style is the one the live map renders from — the same document Android
    /// ships as an asset. If it stops being readable, downloads and rendering silently
    /// disagree about the tile URL, which is the one thing that breaks offline.
    func testEsriStyleIsTheBundledDocument() {
        let json = SatelliteProvider.esri.styleJSON()
        XCTAssertTrue(json.contains("\"version\": 8"))
        XCTAssertTrue(json.contains("server.arcgisonline.com"))
    }

    func testMapboxStyleCarriesTheTokenInTheTileURL() {
        let json = SatelliteProvider.mapboxStyleJSON(token: "TESTTOKEN")
        XCTAssertTrue(json.contains("access_token=TESTTOKEN"))
        XCTAssertTrue(json.contains("api.mapbox.com"))
    }

    // MARK: - Region status

    /// The list must never present a partial region as finished — the row is written
    /// when a download STARTS, so "listed" is not "cached".
    func testRegionStatusDistinguishesPartialFromComplete() {
        XCTAssertEqual(regionStatusText(complete: nil, fraction: nil, bytes: 0),
                       "status unknown")
        XCTAssertEqual(regionStatusText(complete: true, fraction: 1, bytes: 45_000_000),
                       "complete · 45 MB")
        XCTAssertEqual(regionStatusText(complete: false, fraction: 0.42, bytes: 20_000_000),
                       "incomplete — 42% of tiles · 20 MB")
        XCTAssertEqual(regionStatusText(complete: false, fraction: nil, bytes: 1_000_000),
                       "incomplete · 1 MB")
    }
}
