import CoreLocation
import MapLibre
import SwiftUI

/// Download maps — frame a launch area, choose how deep to cache, download it for use
/// with no signal.
///
/// Mirrors Android's `DownloadMapScreen`. The user pans and zooms the satellite map to
/// frame a site, picks a maximum zoom, sees a live tile-count and storage estimate, and
/// downloads. Downloaded regions then render in the live map with no connectivity.
/// Existing regions are listed with their completion status, and can be resumed or
/// deleted.
///
/// **A download outlives this screen** — its state lives in `OfflineDownloadRepository`,
/// not here, so leaving and coming back re-attaches to the running download rather than
/// showing a blank slate with the Download button armed for a second, overlapping region.
struct DownloadMapView: View {

    /// The phone's own position, for the picker's opening camera. Shared with the live
    /// map rather than a second `CLLocationManager` — one manager, one authorisation.
    @ObservedObject var phone: PhoneLocation

    @StateObject private var downloads = OfflineDownloadRepository.shared

    @State private var provider = MapProviderPrefs.get()
    @State private var bounds: GeoBounds?
    @State private var maxZoom = 17
    @State private var siteName = ""

    @State private var presets: [LaunchSite] = []
    /// A request to re-frame the picker camera. The token makes repeat selections
    /// re-fire, so picking the same site again brings you back to it after panning away.
    @State private var moveRequest: MapMoveRequest?

    // The Lat, Lon box is two things at once: a readout of where the map is pointed, and
    // an entry box for pointing it somewhere. `mapCenter` is the readout, tracked live
    // through the gesture; `latLonText` is the edit buffer, which only takes over while
    // the field has focus. Seeding the buffer from the centre on focus means the user
    // edits the number they were just looking at instead of a stale one.
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var latLonText = ""
    @State private var latLonEditing = false
    @State private var latLonError = false
    @FocusState private var latLonFocused: Bool

    /// Default box size when jumping to a manually-entered coordinate.
    private static let manualExtentKm = 8.0
    /// Largest region we will accept. Past this a download is long enough to be a mistake.
    private static let maxRegionBytes = 1_000_000_000

    /// Always cache down to the provider's floor rather than maxZoom − N: each lower
    /// level has ~4× fewer tiles, so the whole context pyramid costs almost nothing,
    /// while omitting it leaves the map blank offline at any zoomed-out level.
    private var minZoom: Int { min(provider.minOfflineZoom, maxZoom) }

    private var downloading: Bool { downloads.current?.progress.isDownloading ?? false }

    private var latLonDisplay: String {
        latLonEditing ? latLonText : (mapCenter.map(formatLatLon) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            controls
        }
        .background(SPColor.background)
        .onAppear {
            presets = LaunchSiteRepository.load()
            downloads.refreshRegions()
        }
    }

    // MARK: - Region picker

    /// Square on purpose. The download takes the VISIBLE bounds, so the preview's shape
    /// becomes the region's shape: a squat viewport silently inflates the region
    /// sideways. A square also matches how coverage is actually used — the live map
    /// rotates with the compass, so a region must survive any bearing, and matching the
    /// live map's portrait shape would go blank at the edges the moment it swings 90°.
    private var picker: some View {
        RegionPickerMap(provider: provider,
                        initialCentre: phone.coordinate,
                        moveRequest: moveRequest,
                        onBoundsChanged: { bounds = $0 },
                        onCenterChanged: { mapCenter = $0 })
            // Recreated when the imagery source changes, as Android's `key(provider)` does.
            .id(provider)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                // Scrim behind the hint: plain text over satellite imagery is illegible
                // on pale terrain — it disappeared entirely over the Black Rock playa.
                Text("Pan & zoom to frame the launch area")
                    .font(SPFont.labelMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Self.mapHintScrim, in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
    }

    /// Semi-transparent backing for map-overlay text, matching Android's value.
    private static let mapHintScrim = Color(hex: 0x5D6F96).opacity(0.75)

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                presetPicker
                latLonRow
                if latLonError {
                    Text("Enter as \"lat, lon\" in decimal degrees (e.g. 47.6205, -122.5490).")
                        .font(SPFont.bodySmall)
                        .foregroundStyle(SPColor.error)
                }
                providerRow
                zoomRow
                estimateLines
                ConfigTextRow(title: "Site name", text: $siteName,
                              enabled: !downloading, maxLength: 64)
                progressBlock
                downloadButton
                regionList
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Preset sites from the user-editable CSV. Selecting one frames it on the map; the
    /// download still takes whatever is visible, so the estimate always matches.
    private var presetPicker: some View {
        Menu {
            ForEach(presets) { site in
                Button("\(site.name)  (\(Int(site.widthKm))x\(Int(site.heightKm)) km)") {
                    moveRequest = MapMoveRequest(bounds: site.bounds)
                    if siteName.trimmingCharacters(in: .whitespaces).isEmpty {
                        siteName = site.name
                    }
                }
            }
        } label: {
            Text(presets.isEmpty
                 ? "No preset sites — see \(LaunchSiteRepository.displayPath)"
                 : "Go to preset site…")
                .font(SPFont.labelLarge)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(downloading || presets.isEmpty)
    }

    /// Manual coordinate entry — jump straight to a lat/lon.
    private var latLonRow: some View {
        HStack(alignment: .center, spacing: 8) {
            OutlinedFieldChrome(title: "Lat, Lon", enabled: !downloading) {
                ZStack(alignment: .leading) {
                    // Only on screen until the map's first camera event fills the box
                    // with the centre. Greyed because at the default placeholder colour
                    // the sample read as a coordinate already entered rather than as the
                    // format to use.
                    if latLonDisplay.isEmpty {
                        Text("47.6205, -122.5490")
                            .foregroundStyle(SPColor.outline)
                    }
                    TextField("", text: Binding(
                        get: { latLonDisplay },
                        set: { new in
                            // Keep only what `parseLatLon` reads: digits, sign, decimal
                            // point, and the comma or space separating the pair. This
                            // filter is the actual constraint — it also covers paste.
                            latLonText = new.filter { $0.isNumber || ".,- ".contains($0) }
                            latLonError = false
                        }))
                        .keyboardType(.numbersAndPunctuation)
                        .submitLabel(.go)
                        .focused($latLonFocused)
                        .disabled(downloading)
                        .onSubmit(goToLatLon)
                }
                .foregroundStyle(latLonError ? SPColor.error : SPColor.onBackground)
            }
            .onChange(of: latLonFocused) { focused in
                // Seed the edit buffer from what is on screen — the map centre — so
                // tapping in edits that number rather than whatever was typed the last
                // time the field was focused.
                if focused && !latLonEditing { latLonText = latLonDisplay }
                latLonEditing = focused
                // Leaving the field puts the map centre back in the box, so a complaint
                // about what was typed no longer has anything to point at.
                if !focused { latLonError = false }
            }

            Button("Go", action: goToLatLon)
                .buttonStyle(.borderedProminent)
                .disabled(downloading || latLonDisplay.isEmpty)
        }
    }

    /// Shared by the Go button and by Go on the keyboard, so the shortcut is that button
    /// rather than a second, subtly different path.
    private func goToLatLon() {
        if let p = parseLatLon(latLonDisplay) {
            // Moving the camera makes the readout catch up on its own, so hand the
            // screen back: focus, and the keyboard over the map, are no longer needed.
            moveRequest = MapMoveRequest(bounds: boundsAround(lat: p.latitude, lon: p.longitude,
                                                              widthKm: Self.manualExtentKm,
                                                              heightKm: Self.manualExtentKm))
            latLonFocused = false
        } else if !latLonDisplay.trimmingCharacters(in: .whitespaces).isEmpty {
            // Unparseable: keep focus so the fix is a straight retype. Dropping focus
            // here would revert the box to the map centre and leave the error explaining
            // text that is no longer on screen.
            latLonError = true
        } else {
            latLonFocused = false
        }
    }

    /// Imagery source toggle. A provider without a token is offered but disabled, and
    /// says why.
    ///
    /// Filled for the selected source, outlined for the others — Android's `Button`
    /// against `OutlinedButton` in the same row, spelled the same way here rather than
    /// through a type-erased style, which is the SwiftUI way to say it and reads as the
    /// two controls it is.
    private var providerRow: some View {
        HStack(spacing: 8) {
            ForEach(SatelliteProvider.allCases) { p in
                if p == provider {
                    Button { pick(p) } label: { providerLabel(p) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!p.isAvailable)
                } else {
                    Button { pick(p) } label: { providerLabel(p) }
                        .buttonStyle(.bordered)
                        .disabled(!p.isAvailable || downloading)
                }
            }
        }
    }

    private func providerLabel(_ p: SatelliteProvider) -> some View {
        Text(p.isAvailable ? p.displayName : "\(p.displayName) (no token)")
            .font(SPFont.labelLarge)
            .frame(maxWidth: .infinity)
    }

    private func pick(_ p: SatelliteProvider) {
        provider = p
        maxZoom = min(max(maxZoom, 14), p.maxOfflineZoom)
        MapProviderPrefs.set(p)
    }

    /// Slider plus a live inset showing the imagery AT the chosen maximum zoom, so the
    /// number means something: past ~z19 the imagery is upscaled, and the inset makes
    /// that visible — it stops getting sharper — instead of leaving the user to guess.
    private var zoomRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Detail (max zoom): z\(maxZoom)")
                    .font(SPFont.titleSmall)
                    .foregroundStyle(SPColor.onBackground)
                Slider(value: Binding(get: { Double(maxZoom) },
                                      set: { maxZoom = Int($0.rounded()) }),
                       in: 14...Double(provider.maxOfflineZoom),
                       step: 1)
                    .disabled(downloading)
                Text(zoomHint(maxZoom, provider: provider))
                    .font(SPFont.bodySmall)
                    .foregroundStyle(SPColor.onSurfaceVariant)
            }
            VStack(spacing: 2) {
                DetailPreviewMap(provider: provider, center: bounds?.center, zoom: maxZoom)
                    .id(provider)
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("detail @ z\(maxZoom)")
                    .font(SPFont.labelSmall)
                    .foregroundStyle(SPColor.onSurfaceVariant)
            }
        }
    }

    /// Coverage first: sizing a region is a "does this contain the flight and its drift
    /// footprint?" question, not a "does this match my screen?" one.
    private var estimateLines: some View {
        let tiles = bounds.map { TileMath.tileCount($0, minZoom: minZoom, maxZoom: maxZoom) } ?? 0
        let estBytes = bounds.map {
            TileMath.estimateBytes($0, minZoom: minZoom, maxZoom: maxZoom, provider: provider)
        } ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            Text(bounds.map { b -> String in
                let (w, h) = b.groundSizeKm
                return String(format: "Coverage: ≈ %.1f × %.1f km", w, h)
            } ?? "Coverage: —")
            Text("Caching z\(minZoom)–z\(maxZoom)  ·  ~\(formatCount(tiles)) tiles  ·  "
                 + "~\(formatBytes(estBytes))")
        }
        .font(SPFont.telemetry)
        .foregroundStyle(SPColor.onBackground)
        // Wrap, never truncate. These lines are long, monospaced and scale with Dynamic
        // Type, so on a narrow phone or at a large text size the last field — the SIZE,
        // which is the number the whole screen exists to report — was the part that fell
        // off the right edge. Compose wraps by default; `fixedSize` vertically is how
        // SwiftUI is told to grow a line into two rather than clip it.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Named in every state, because this block also reports a download the user
    /// started, navigated away from, and came back to — "which one?" is a real question.
    @ViewBuilder
    private var progressBlock: some View {
        if let download = downloads.current {
            let name = download.name
            switch download.progress {
            case let .downloading(completed, required, bytes, _):
                if let fraction = download.progress.fraction {
                    ProgressView(value: fraction)
                    Text("Downloading “\(name)”… \(Int(fraction * 100))%  "
                         + "(\(completed)/\(required) tiles, \(formatBytes(Int(bytes))))")
                        .font(SPFont.bodySmall)
                        .foregroundStyle(SPColor.onBackground)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // The required-tile count is still a lower bound; any percentage here
                    // would read near 100% and then fall back as the real total resolves.
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Preparing “\(name)”… (\(completed) tiles, \(formatBytes(Int(bytes))))")
                        .font(SPFont.bodySmall)
                        .foregroundStyle(SPColor.onBackground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Keeps running if you leave this screen — it stops only if the app closes.")
                        .font(SPFont.bodySmall)
                        .foregroundStyle(SPColor.onSurfaceVariant)
                    Spacer()
                    // Only once the pack exists — between the button press and the pack
                    // being created there is nothing to stop.
                    Button("Cancel") { downloads.cancel() }
                        .buttonStyle(.borderless)
                        .disabled(!download.cancelable)
                }
            case .complete:
                finishedResult("✓ “\(name)” downloaded — renders offline on the map.",
                               colour: SPColor.primary)
            case let .failed(reason):
                finishedResult("✗ “\(name)” failed: \(reason)", colour: SPColor.error)
            case .canceled:
                finishedResult("“\(name)” canceled — what downloaded is kept, resume it below.",
                               colour: SPColor.onSurfaceVariant)
            }
        }
    }

    /// A finished download's outcome, with a dismiss. The result outlives the screen, so
    /// without this it would greet the user on every later visit with no way to clear it.
    private func finishedResult(_ text: String, colour: Color) -> some View {
        HStack {
            Text(text)
                .font(SPFont.bodyMedium)
                .foregroundStyle(colour)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { downloads.clearFinished() }
                .buttonStyle(.borderless)
        }
    }

    /// The size limit states itself in the label. As a separate warning line it sat rows
    /// away from the control it disables, so an over-budget region read as a dead button.
    private var downloadButton: some View {
        let estBytes = bounds.map {
            TileMath.estimateBytes($0, minZoom: minZoom, maxZoom: maxZoom, provider: provider)
        } ?? 0
        let overBudget = estBytes > Self.maxRegionBytes
        return Button {
            guard let b = bounds else { return }
            let name = siteName.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Launch site" : siteName
            Task {
                await OfflineMapManager(provider: provider)
                    .downloadRegion(name: name, bounds: b, minZoom: minZoom, maxZoom: maxZoom)
            }
        } label: {
            Text(overBudget ? "Over 1 GB — tighten the area or lower the zoom"
                            : "Download this area for offline")
                .font(SPFont.labelLarge)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(bounds == nil || downloading || overBudget)
    }

    /// "Offline regions", not "Downloaded regions": the row is written when a download
    /// STARTS, so this list has always included partial regions — presenting them as
    /// finished is the one thing it must never do.
    @ViewBuilder
    private var regionList: some View {
        if !downloads.regions.isEmpty {
            Text("Offline regions")
                .font(SPFont.titleSmall)
                .foregroundStyle(SPColor.onBackground)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(downloads.regions) { info in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name)
                                    .font(SPFont.bodyLarge)
                                    .foregroundStyle(SPColor.onBackground)
                                Text(regionStatusText(complete: info.complete,
                                                      fraction: info.fraction,
                                                      bytes: info.bytes))
                                    .font(SPFont.bodySmall)
                                    .foregroundStyle(info.complete == true
                                                     ? SPColor.onSurfaceVariant : SPColor.error)
                            }
                            Spacer()
                            // Resuming picks up where the interrupted download stopped;
                            // tiles already downloaded are not refetched.
                            if info.complete == false {
                                Button("Resume") {
                                    Task {
                                        await OfflineMapManager(provider: provider)
                                            .resumeRegion(info)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(downloading)
                            }
                            // Deleting is blocked outright during a download: MapLibre
                            // forbids any further call on a deleted pack, and this list
                            // cannot tell which row is the one being downloaded into.
                            Button {
                                OfflineMapManager(provider: provider).deleteRegion(info)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(SPColor.onSurfaceVariant)
                            }
                            .buttonStyle(.borderless)
                            .disabled(downloading)
                            .accessibilityLabel("Delete region")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}

/// One line per region saying whether it will actually render offline.
///
/// Takes the three values rather than the whole `OfflineRegionInfo` so it can be tested
/// without conjuring an `MLNOfflinePack`, which is invalid unless MapLibre made it.
func regionStatusText(complete: Bool?, fraction: Double?, bytes: UInt64) -> String {
    switch (complete, fraction) {
    case (nil, _):
        return "status unknown"
    case (true?, _):
        return "complete · \(formatBytes(Int(bytes)))"
    case (false?, let fraction?):
        return "incomplete — \(Int(fraction * 100))% of tiles · \(formatBytes(Int(bytes)))"
    default:
        return "incomplete · \(formatBytes(Int(bytes)))"
    }
}

/// A request to re-frame a picker camera. The id makes repeat selections re-fire.
struct MapMoveRequest: Equatable {
    let bounds: GeoBounds
    let id = UUID()
}

// MARK: - Maps

/// Lightweight map for framing a download region.
///
/// Reports the visible bounds on every camera idle, and the centre continuously through
/// the gesture — the bounds drive the tile and size estimate, which is too costly to
/// recompute per frame, while the centre is a cheap read feeding a live coordinate
/// readout. Separate from `FlightMapView`, which carries the rocket layers.
private struct RegionPickerMap: UIViewRepresentable {
    let provider: SatelliteProvider
    /// Where to open, applied ONCE when it first becomes available — see `apply`.
    let initialCentre: CLLocationCoordinate2D?
    let moveRequest: MapMoveRequest?
    let onBoundsChanged: (GeoBounds) -> Void
    let onCenterChanged: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: OfflineStyleFile.url(for: provider))
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = context.coordinator
        // **The visible bounds ARE the download region**, so nothing may quietly inset
        // them. MapLibre otherwise adjusts `contentInset` for navigation bars and other
        // obscuring ancestors — this map lives in a sheet under a navigation bar — and
        // an inset excludes part of the frame from the viewport, which would size every
        // region differently from the square the user framed.
        //
        // (It does NOT silence MapLibre's "automaticallyAdjustsScrollViewInsets is
        // deprecated" notice: that is logged from the hosting view controller's own
        // deprecated flag, which a SwiftUI app does not own.)
        map.automaticallyAdjustsContentInset = false
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        // Android disables rotation here: the download takes the visible bounds, and a
        // rotated viewport's bounds are its bounding box, which is bigger than what is
        // on screen.
        map.allowsRotating = false
        map.allowsTilting = false
        // No opening camera here: it is set from the phone's position the moment there
        // is one (see `applyInitialCentre`). Until then MapLibre's own default stands,
        // which is what Android shows today.
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyInitialCentre(initialCentre, to: map)
        context.coordinator.apply(moveRequest, to: map)
    }

    /// Opening zoom: **multi-state**, so the launch site you are driving to is on screen
    /// before you touch anything.
    ///
    /// MapLibre's world is 512·2^z points wide, so on a ~390 pt phone z5 shows roughly
    /// 950 km across — Washington to central Idaho, or most of California. Deep enough to
    /// place yourself, wide enough that a site two states away is a pan rather than a
    /// search.
    static let initialZoom: Double = 5

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: RegionPickerMap
        private var lastMoveRequest: UUID?
        private var placedInitialCentre = false

        init(_ parent: RegionPickerMap) { self.parent = parent }

        /// Open on the phone's own position, **once**.
        ///
        /// Once, because `updateUIView` runs on every camera report — this screen reports
        /// the centre continuously through a gesture — so re-centring here would drag the
        /// map back under the user's finger. A fix that arrives after the screen opens
        /// still moves the camera, which is the point: it is the first useful position,
        /// not a position the user chose.
        func applyInitialCentre(_ centre: CLLocationCoordinate2D?, to map: MLNMapView) {
            guard !placedInitialCentre, let centre,
                  CLLocationCoordinate2DIsValid(centre) else { return }
            placedInitialCentre = true
            map.setCenter(centre, zoomLevel: RegionPickerMap.initialZoom, animated: false)
        }

        func apply(_ request: MapMoveRequest?, to map: MLNMapView) {
            guard let request, request.id != lastMoveRequest else { return }
            lastMoveRequest = request.id
            // Picking a site or typing a coordinate IS a chosen position, so a location
            // fix arriving afterwards must not pull the camera back to the phone.
            placedInitialCentre = true
            // Padding matches Android's 48 px inset, so the framed site is not flush to
            // the edge of the box being downloaded.
            map.setVisibleCoordinateBounds(request.bounds.mln,
                                           edgePadding: UIEdgeInsets(top: 16, left: 16,
                                                                     bottom: 16, right: 16),
                                           animated: true, completionHandler: nil)
        }

        func mapView(_ map: MLNMapView, didFinishLoading style: MLNStyle) {
            report(map)
        }

        func mapView(_ map: MLNMapView, regionIsChangingWith reason: MLNCameraChangeReason) {
            parent.onCenterChanged(map.centerCoordinate)
        }

        func mapView(_ map: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason,
                     animated: Bool) {
            report(map)
        }

        private func report(_ map: MLNMapView) {
            parent.onBoundsChanged(GeoBounds(map.visibleCoordinateBounds))
            parent.onCenterChanged(map.centerCoordinate)
        }
    }
}

/// Non-interactive inset showing the imagery at the region centre at exactly `zoom` — a
/// preview of the detail the chosen maximum zoom actually buys.
///
/// Deliberately a separate map rather than zooming the picker: the picker's visible
/// bounds ARE the download region, so moving its camera would silently redefine what
/// gets downloaded.
private struct DetailPreviewMap: UIViewRepresentable {
    let provider: SatelliteProvider
    let center: CLLocationCoordinate2D?
    let zoom: Int

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: OfflineStyleFile.url(for: provider))
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.automaticallyAdjustsContentInset = false     // see RegionPickerMap
        // Inert: it is a readout, not a control.
        map.allowsScrolling = false
        map.allowsZooming = false
        map.allowsRotating = false
        map.allowsTilting = false
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        map.compassView.isHidden = true
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        guard let center else { return }
        map.setCenter(center, zoomLevel: Double(zoom), animated: false)
    }
}

/// The style document as a **file** URL, for rendering.
///
/// Rendering is happy with a local style; only the offline downloader is not
/// (ADR-0014), which is what `LocalStyleServer` exists for. Esri's style ships in the
/// bundle; Mapbox's is generated around the token, so it is written to a cache file
/// rather than embedded.
enum OfflineStyleFile {
    static func url(for provider: SatelliteProvider) -> URL? {
        switch provider {
        case .esri:
            return Bundle.main.url(forResource: "satellite_style", withExtension: "json")
        case .mapbox:
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mapbox_satellite_style.json")
            try? provider.styleJSON().write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
}
