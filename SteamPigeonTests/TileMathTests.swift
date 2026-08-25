import XCTest
@testable import SteamPigeon

/// The tile count and storage estimate the download screen shows.
///
/// This number is the one the user decides on — "is this small enough to finish tonight
/// on hotel wi-fi?" — so being wrong by a factor is not cosmetic. It is also the one
/// piece of the offline path that can be checked without a network, a map view, or a
/// launch site.
final class TileMathTests: XCTestCase {

    // The one region either platform has actually measured: 9.1 x 9.1 km near 47.6 N,
    // cached z10-z17, which downloaded 139 MB. Everything anchored below is anchored
    // here. Android pins the same numbers in `TileMathTest.kt` (`3f921a4`).
    private let measuredRegion = boundsAround(lat: 47.6, lon: -122.4,
                                              widthKm: 9.1, heightKm: 9.1)
    private let measuredBytes = 139_000_000.0
    private let measuredMinZoom = 10
    private let measuredMaxZoom = 17

    /// Zoom 0 is one tile for the whole world, whatever the bounds.
    func testWholeWorldAtZoomZeroIsOneTile() {
        let world = GeoBounds(north: 80, south: -80, east: 179, west: -179)
        XCTAssertEqual(TileMath.tileCount(world, at: 0), 1)
    }

    // MARK: - The zoom convention

    /// The style declares 256-px tiles against MapLibre's 512-px logical grid, so the
    /// tile URL is always one level deeper than the map zoom the user picked.
    func testSourceZoomIsOneDeeperThanMapZoom() {
        XCTAssertEqual(TileMath.sourceZoom(of: 17), 18)
        XCTAssertEqual(TileMath.sourceZoom(of: 10), 11)
    }

    /// Each level is 4x the one above, so counting the wrong grid is a clean factor of
    /// ~4 — which is exactly the 3.94 MapLibre's own resource count reported against the
    /// old estimate.
    func testAZoomRangeCostsFourTimesWhatTheMapZoomGridWouldSuggest() {
        let counted = TileMath.tileCount(measuredRegion,
                                         minZoom: measuredMinZoom, maxZoom: measuredMaxZoom)
        let mapZoomGrid = (measuredMinZoom...measuredMaxZoom)
            .reduce(0) { $0 + TileMath.tileCount(measuredRegion, at: $1) }
        let ratio = Double(counted) / Double(mapZoomGrid)
        XCTAssertGreaterThan(ratio, 3.8, "expected ~3.9x, got \(ratio)")
        XCTAssertLessThan(ratio, 4.0, "expected ~3.9x, got \(ratio)")
    }

    // MARK: - The estimate against reality

    /// The whole point of the number. Within 15%: tighter would be false precision,
    /// since the bounds here are reconstructed from "9.1 x 9.1 km near 47.6 N" rather
    /// than from the exact corners that were downloaded.
    func testTheByteEstimateLandsOnTheOneRegionActuallyMeasured() {
        let est = Double(TileMath.estimateBytes(measuredRegion,
                                                minZoom: measuredMinZoom,
                                                maxZoom: measuredMaxZoom,
                                                provider: .mapbox))
        let ratio = est / measuredBytes
        XCTAssertGreaterThan(ratio, 0.85,
                             "estimate \(est / 1_000_000) MB vs measured 139 MB")
        XCTAssertLessThan(ratio, 1.15,
                          "estimate \(est / 1_000_000) MB vs measured 139 MB")
    }

    /// Guards the direction, not the constant: if either half of the fix is reverted —
    /// the source-zoom count or the calibration — the estimate drops back under the
    /// measured download, and the 1 GB guard silently goes back to passing regions that
    /// are really over budget. **Low is the dangerous direction here**, because the
    /// guard reads this number.
    func testTheOldArithmeticWouldHaveBeenLowByMoreThanHalf() {
        let est = TileMath.estimateBytes(measuredRegion,
                                         minZoom: measuredMinZoom, maxZoom: measuredMaxZoom,
                                         provider: .mapbox)
        XCTAssertGreaterThan(est, 100_000_000,
                             "the estimate must not fall back under the measured 139 MB")
    }

    /// Esri has no download of its own to anchor against, so it carries the same
    /// correction: both tables were built the same way in the same commit, and
    /// correcting only the one with an anchor would leave the other ~3.9x high.
    func testBothProvidersAreCalibratedTheSameWay() {
        let tiles = Double(TileMath.tileCount(measuredRegion,
                                              minZoom: measuredMinZoom, maxZoom: measuredMaxZoom))
        let mapboxPerTile = Double(TileMath.estimateBytes(measuredRegion,
                                                          minZoom: measuredMinZoom,
                                                          maxZoom: measuredMaxZoom,
                                                          provider: .mapbox)) / tiles
        let esriPerTile = Double(TileMath.estimateBytes(measuredRegion,
                                                       minZoom: measuredMinZoom,
                                                       maxZoom: measuredMaxZoom,
                                                       provider: .esri)) / tiles
        XCTAssertTrue((10_000...16_000).contains(mapboxPerTile), "mapbox \(mapboxPerTile) B/tile")
        XCTAssertTrue((12_000...20_000).contains(esriPerTile), "esri \(esriPerTile) B/tile")
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

    func testPyramidIsTheSumOfItsSourceLevels() {
        let b = boundsAround(lat: 40.84, lon: -119.11, widthKm: 20, heightKm: 20)
        let summed = (10...17).reduce(0) { $0 + TileMath.tileCount(b, at: TileMath.sourceZoom(of: $1)) }
        XCTAssertEqual(TileMath.tileCount(b, minZoom: 10, maxZoom: 17), summed)
    }

    /// Three quarters of the download is its single deepest level, which is why the
    /// calibration anchored there carries the whole estimate.
    func testTheDeepestLevelDominatesTheEstimate() {
        let total = Double(TileMath.tileCount(measuredRegion,
                                              minZoom: measuredMinZoom, maxZoom: measuredMaxZoom))
        let deepest = Double(TileMath.tileCount(measuredRegion,
                                                at: TileMath.sourceZoom(of: measuredMaxZoom)))
        XCTAssertGreaterThan(deepest / total, 0.7,
                             "deepest level is \(deepest / total) of the pyramid")
    }

    /// The context pyramid below the chosen maximum is nearly free — the argument for
    /// always caching down to the provider's floor rather than to maxZoom − N.
    func testTheLevelsBelowTheMaximumCostAlmostNothing() {
        let b = boundsAround(lat: 47.5, lon: -122.25, widthKm: 10, heightKm: 10)
        let deepest = TileMath.tileCount(b, at: TileMath.sourceZoom(of: 17))
        let context = TileMath.tileCount(b, minZoom: 10, maxZoom: 16)
        XCTAssertLessThan(Double(context), Double(deepest) * 0.5)
    }

    /// Per level, not a flat average — and priced on the SOURCE level, whose table entry
    /// can differ from the map level's. z19 is where that bites hardest: the map level
    /// is still in the 19 kB band while the tile actually fetched is z20, where Mapbox's
    /// native imagery has run out and the bytes collapse to 9.5 kB.
    func testTheEstimatePricesTheLevelItActuallyFetches() {
        let b = boundsAround(lat: 47.5, lon: -122.25, widthKm: 5, heightKm: 5)
        let atMapZoom19 = Double(TileMath.estimateBytes(b, minZoom: 19, maxZoom: 19,
                                                        provider: .mapbox))
        let tiles = Double(TileMath.tileCount(b, at: TileMath.sourceZoom(of: 19)))
        let perTile = atMapZoom19 / tiles
        // 9,500 x 0.68 = 6,460 — the z20 figure, not z19's 19,000.
        XCTAssertEqual(perTile, 9_500 * 0.68, accuracy: 1,
                       "map z19 must be priced as the source z20 tiles it fetches")
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

    /// A real region, priced end to end: the number someone actually reads. BALLS at
    /// Black Rock, 20 x 20 km to z17, is **most of the 1 GB budget** — it used to quote
    /// a comfortable ~230 MB, and the download was never that size. Hundreds of
    /// megabytes is the honest answer, and it is why the guard exists.
    func testATypicalLaunchSiteIsAPlausibleDownload() {
        let b = boundsAround(lat: 40.844967, lon: -119.11217, widthKm: 20, heightKm: 20)
        let bytes = TileMath.estimateBytes(b, minZoom: 10, maxZoom: 17, provider: .esri)
        XCTAssertGreaterThan(bytes, 300_000_000)
        XCTAssertLessThan(bytes, 1_000_000_000)
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
