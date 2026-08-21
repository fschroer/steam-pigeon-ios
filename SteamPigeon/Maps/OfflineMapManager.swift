import Foundation
import MapLibre
import Network

// ---------------------------------------------------------------------------
//  Offline map region download and management for the live map.
//
//  MapLibre stores offline packs in one app-wide database, and any map view that
//  requests a tile URL present there is served from disk — so once a region is
//  downloaded here, the live satellite map renders it with no connectivity. There is
//  no wiring beyond matching the tile source URL, which both sides get from the same
//  style JSON.
//
//  ADR-0014: the offline downloader accepts ONLY an http(s) style URL — it rejects
//  `asset:`, `data:` and `file:`, stalling a region at "0/1 tiles". The style is
//  therefore served from a short-lived localhost server for the duration of a
//  download, exactly as Android does. `NSAllowsLocalNetworking` in the Info.plist is
//  required by this, not leftover scaffolding — it is the counterpart of Android's
//  `network_security_config.xml`.
// ---------------------------------------------------------------------------

extension GeoBounds {
    var mln: MLNCoordinateBounds {
        MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: south, longitude: west),
            ne: CLLocationCoordinate2D(latitude: north, longitude: east))
    }

    init(_ b: MLNCoordinateBounds) {
        self.init(north: b.ne.latitude, south: b.sw.latitude,
                  east: b.ne.longitude, west: b.sw.longitude)
    }
}

/// How a download is going.
enum OfflineProgress: Equatable {
    /// `required` is only a real total once `precise` is true. Before that MapLibre
    /// reports it as a lower bound, so a percentage computed from it reads far too high
    /// — often 100% — in the opening seconds, then visibly goes backwards.
    case downloading(completed: UInt64, required: UInt64, bytes: UInt64, precise: Bool)
    case complete
    case failed(String)
    /// Stopped by the user. What downloaded stays in the database, resumable.
    case canceled

    /// nil until it can be trusted; callers show an indeterminate bar instead.
    var fraction: Double? {
        guard case let .downloading(completed, required, _, precise) = self,
              precise, required > 0 else { return nil }
        return min(max(Double(completed) / Double(required), 0), 1)
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// A pack in the offline database together with how much of it is actually on disk.
///
/// The row exists from the moment a download is created, so presence in this list means
/// "started", never "finished" — `complete` is what says the region will render offline.
struct OfflineRegionInfo: Identifiable {
    let pack: MLNOfflinePack
    let name: String
    /// Bytes this region has downloaded. Overlapping regions share tiles, so these do
    /// not sum to the size of the offline database.
    let bytes: UInt64
    /// nil when the pack has not reported yet — unknown rather than guessed.
    let complete: Bool?
    /// Downloaded share, or nil while the required total is still a lower bound.
    let fraction: Double?
    /// Source this region was downloaded from; nil for packs predating that metadata.
    let provider: SatelliteProvider?

    var id: ObjectIdentifier { ObjectIdentifier(pack) }
}

/// Whether a pack is finished, without the false positive built into "completed ≥
/// expected".
///
/// The expected count is only a real total once MapLibre knows it; until the style and
/// tile sources resolve it is a lower bound, initially zero. A pack that has just been
/// created, or one interrupted before it got going, therefore reports 0 ≥ 0 and calls
/// itself complete. Requiring precision costs nothing for a genuinely finished pack —
/// its sources are by definition downloaded — and stops a barely-started one from
/// listing as fully cached.
func isDefinitelyComplete(_ p: MLNOfflinePackProgress) -> Bool {
    isPrecise(p) && p.countOfResourcesExpected > 0
        && p.countOfResourcesCompleted >= p.countOfResourcesExpected
}

/// MapLibre sets `maximumResourcesExpected` to `UINT64_MAX` until it knows the exact
/// number, which is the iOS spelling of Android's `isRequiredResourceCountPrecise`.
func isPrecise(_ p: MLNOfflinePackProgress) -> Bool {
    p.maximumResourcesExpected != UInt64.max
}

/// The one in-flight region download, held for the life of the process.
///
/// **A download does not belong to the download screen.** It runs inside MapLibre's
/// process-wide offline storage and keeps going whether or not the screen is on
/// display. Screen-local state could not represent that: leaving the screen would throw
/// the progress away, so returning would show a blank slate with the Download button
/// live again, inviting a second overlapping region on top of the one still running.
///
/// Terminal results are kept, not cleared, so a download that ends while the user is
/// elsewhere still reports itself when they come back.
@MainActor
final class OfflineDownloadRepository: NSObject, ObservableObject {

    static let shared = OfflineDownloadRepository()

    struct Download: Equatable {
        let name: String
        let progress: OfflineProgress
        /// True once the pack exists and the download can actually be stopped. Part of
        /// the published state rather than a computed property, so the Cancel button
        /// lights up when the pack lands rather than at some later redraw.
        var cancelable: Bool = false
    }

    /// The active or most recent download, or nil if none has been started this session.
    @Published private(set) var current: Download?
    /// Every pack in the database, with its status.
    @Published private(set) var regions: [OfflineRegionInfo] = []

    /// True while tiles are still being fetched — the gate on starting another download.
    var isRunning: Bool { current?.progress.isDownloading ?? false }

    /// The pack being downloaded into, and the server feeding it its style.
    private var activePack: MLNOfflinePack?
    private var activeServer: LocalStyleServer?

    /// What the active pack IS, as opposed to which object currently represents it.
    ///
    /// MapLibre is explicit that "the pointer values of the `MLNOfflinePack` objects in
    /// the `packs` property change, even if the underlying data for these packs has not
    /// changed". Identifying the download by `===` therefore loses it the moment that
    /// happens: progress notifications arrive for a pack that is not the one held, get
    /// dropped, and the screen sits frozen on the last percentage it saw. Reported from
    /// the phone as "downloads appear to stop when I tap Done then return".
    private var activeIdentity: PackIdentity?

    /// A pack's identity across pointer swaps: the metadata we wrote, plus the style URL,
    /// which carries the ephemeral port unique to the session that created the pack.
    private struct PackIdentity: Equatable {
        let context: Data
        let styleURL: URL?

        init(_ pack: MLNOfflinePack) {
            context = pack.context
            styleURL = pack.region.styleURL
        }
    }

    /// Re-adopt `pack` if it is the active download wearing a new pointer.
    ///
    /// Returns true when `pack` is the one being downloaded, whether or not the object
    /// changed underneath us.
    private func adopt(_ pack: MLNOfflinePack) -> Bool {
        if pack === activePack { return true }
        guard let activeIdentity, PackIdentity(pack) == activeIdentity else { return false }
        activePack = pack
        return true
    }

    private var packsObservation: NSKeyValueObservation?

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(packProgressChanged(_:)),
                           name: NSNotification.Name.MLNOfflinePackProgressChanged, object: nil)
        center.addObserver(self, selector: #selector(packErrored(_:)),
                           name: NSNotification.Name.MLNOfflinePackError, object: nil)
        center.addObserver(self, selector: #selector(packHitTileLimit(_:)),
                           name: NSNotification.Name.MLNOfflinePackMaximumMapboxTilesReached,
                           object: nil)

        // `packs` is nil until the storage has finished loading, and changes whenever a
        // pack is added or removed. Observing it is how the list stays honest without
        // the screen polling.
        packsObservation = MLNOfflineStorage.shared.observe(\.packs, options: [.initial, .new]) {
            [weak self] _, _ in
            Task { @MainActor in self?.rebuildRegions() }
        }
    }

    // MARK: - Publishing

    func publish(name: String, progress: OfflineProgress) {
        if !progress.isDownloading {
            activeServer?.stop()
            activeServer = nil
            activePack = nil
            activeIdentity = nil
        }
        current = Download(name: name, progress: progress, cancelable: activePack != nil)
        rebuildRegions()
    }

    func armCancel(pack: MLNOfflinePack, server: LocalStyleServer?) {
        activePack = pack
        activeIdentity = PackIdentity(pack)
        activeServer = server
        if let current {
            self.current = Download(name: current.name, progress: current.progress,
                                    cancelable: true)
        }
    }

    /// User-requested stop. The partial pack is kept and can be resumed.
    func cancel() {
        guard let pack = activePack else { return }
        // Suspending also stops the progress notifications, so this publish is the last
        // word on the download.
        pack.suspend()
        let name = current?.name ?? ""
        publish(name: name, progress: .canceled)
    }

    /// Drops a finished result once the user has seen it. No-op while one is running.
    func clearFinished() {
        guard !isRunning else { return }
        current = nil
    }

    // MARK: - Regions

    /// Rebuild the list from what MapLibre already holds.
    ///
    /// **This must never call `reloadPacks()`.** That method's own documentation says the
    /// pack pointers change afterwards, and that "if this method is called while a pack
    /// is actively downloading, the behavior is undefined" — and it did exactly that
    /// here, because the screen called this on every appearance. Leaving the download
    /// screen and coming back froze the transfer at whatever percentage it had reached.
    /// MapLibre keeps `packs` current on its own as packs are added and removed, and the
    /// KVO observation above is how this list hears about it, so there is nothing to
    /// force.
    func refreshRegions() {
        rebuildRegions()
    }

    private func rebuildRegions() {
        let packs = MLNOfflineStorage.shared.packs ?? []
        regions = packs.map { pack in
            let meta = OfflinePackContext.decode(pack.context)
            // A pack reports `.unknown` until asked; asking republishes through the
            // progress notification, which is what fills the list in.
            if pack.state == .unknown { pack.requestProgress() }
            let p = pack.progress
            let known = pack.state != .unknown
            return OfflineRegionInfo(
                pack: pack,
                name: meta.name.isEmpty ? "(unnamed)" : meta.name,
                bytes: p.countOfBytesCompleted,
                complete: known ? isDefinitelyComplete(p) : nil,
                fraction: isPrecise(p) && p.countOfResourcesExpected > 0
                    ? min(max(Double(p.countOfResourcesCompleted)
                              / Double(p.countOfResourcesExpected), 0), 1)
                    : nil,
                provider: meta.provider)
        }
    }

    // MARK: - Notifications

    @objc private func packProgressChanged(_ note: Notification) {
        Task { @MainActor in
            rebuildRegions()
            guard let pack = note.object as? MLNOfflinePack, adopt(pack),
                  let name = current?.name else { return }
            let p = pack.progress
            if isDefinitelyComplete(p) {
                pack.suspend()                       // stop the observer chattering
                publish(name: name, progress: .complete)
            } else {
                publish(name: name,
                        progress: .downloading(completed: p.countOfResourcesCompleted,
                                               required: p.countOfResourcesExpected,
                                               bytes: p.countOfBytesCompleted,
                                               precise: isPrecise(p)))
            }
        }
    }

    @objc private func packErrored(_ note: Notification) {
        Task { @MainActor in
            guard let pack = note.object as? MLNOfflinePack, adopt(pack),
                  let name = current?.name else { return }
            let error = note.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
            publish(name: name, progress: .failed(error?.localizedDescription ?? "unknown error"))
        }
    }

    @objc private func packHitTileLimit(_ note: Notification) {
        Task { @MainActor in
            guard let pack = note.object as? MLNOfflinePack, adopt(pack),
                  let name = current?.name else { return }
            let limit = note.userInfo?[MLNOfflinePackUserInfoKey.maximumCount] as? NSNumber
            publish(name: name,
                    progress: .failed("Tile count limit exceeded: \(limit?.uint64Value ?? 0)"))
        }
    }
}

/// The JSON blob stored on a pack: the site name, and the source it came from.
///
/// The provider is recorded because the style URL is a dead localhost address after the
/// fact and cannot identify the source. Without it, a region downloaded from Mapbox and
/// resumed while Esri is selected would finish with two different imagery sources
/// stitched into one region.
enum OfflinePackContext {
    static func encode(name: String, provider: SatelliteProvider) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["site_name": name,
                                                      "provider": provider.rawValue]))
            ?? Data()
    }

    static func decode(_ data: Data) -> (name: String, provider: SatelliteProvider?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("", nil) }
        let name = obj["site_name"] as? String ?? ""
        let provider = (obj["provider"] as? String).flatMap(SatelliteProvider.init(rawValue:))
        return (name, provider)
    }
}

/// Creates, resumes and deletes offline regions.
@MainActor
struct OfflineMapManager {
    let provider: SatelliteProvider
    var repository: OfflineDownloadRepository = .shared

    /// Downloads every tile for `bounds` across `minZoom…maxZoom`.
    ///
    /// Progress goes to the repository rather than to a caller-supplied closure: the
    /// download outlives whatever screen started it, so its status has to live
    /// somewhere that outlives the screen too.
    func downloadRegion(name: String, bounds: GeoBounds, minZoom: Int, maxZoom: Int) async {
        guard !repository.isRunning else { return }

        // Claim the slot before any async work, so a second tap cannot slip through.
        repository.publish(name: name,
                           progress: .downloading(completed: 0, required: 0, bytes: 0,
                                                  precise: false))

        let server = LocalStyleServer(styleJSON: provider.styleJSON())
        do {
            try await server.start()
        } catch {
            repository.publish(name: name,
                               progress: .failed("Could not start local style server: "
                                                 + error.localizedDescription))
            return
        }

        let region = MLNTilePyramidOfflineRegion(styleURL: server.styleURL,
                                                 bounds: bounds.mln,
                                                 fromZoomLevel: Double(minZoom),
                                                 toZoomLevel: Double(maxZoom))
        let context = OfflinePackContext.encode(name: name, provider: provider)

        do {
            let pack = try await MLNOfflineStorage.shared.addPack(for: region, withContext: context)
            repository.armCancel(pack: pack, server: server)
            pack.resume()
        } catch {
            server.stop()
            repository.publish(name: name, progress: .failed(error.localizedDescription))
        }
    }

    /// Restarts an interrupted download, picking up where it stopped.
    ///
    /// The catch is the style URL. A region's definition is immutable and permanently
    /// records the `127.0.0.1:<port>` address from the session that created it, with an
    /// ephemeral port that is long dead. So the server is re-bound to that exact port
    /// rather than a fresh one. If the port is taken the resume still proceeds: the
    /// style is usually already in the offline database from the first attempt, in
    /// which case nothing fetches it and only the tiles are refetched.
    func resumeRegion(_ info: OfflineRegionInfo) async {
        guard !repository.isRunning else { return }
        repository.publish(name: info.name,
                           progress: .downloading(completed: 0, required: 0, bytes: 0,
                                                  precise: false))

        // Resume on the source the region was started with, not whatever is selected now.
        let styleJSON = (info.provider ?? provider).styleJSON()
        let server = LocalStyleServer(styleJSON: styleJSON)
        let port = LocalStyleServer.portOf(styleURL: info.pack.region.styleURL)
        try? await server.start(preferredPort: port)

        repository.armCancel(pack: info.pack, server: server)
        info.pack.resume()
    }

    func deleteRegion(_ info: OfflineRegionInfo) {
        MLNOfflineStorage.shared.removePack(info.pack) { _ in
            Task { @MainActor in repository.refreshRegions() }
        }
    }
}

/// Single-purpose localhost HTTP/1.1 server that returns one style document for any
/// request, bound to 127.0.0.1 for the duration of a download.
///
/// Required by ADR-0014, not a workaround invented here: MapLibre's offline downloader
/// refuses a `file:` style URL and stalls the region at "0/1 tiles". Android solves it
/// the same way, down to re-binding the original port when resuming.
final class LocalStyleServer {

    private let styleJSON: String
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(styleJSON: String) { self.styleJSON = styleJSON }

    var styleURL: URL { URL(string: "http://127.0.0.1:\(port)/style.json")! }

    /// The port out of a region's recorded address, or 0 (any free port) when it cannot
    /// be read — a region created before this scheme, or a hosted style URL, in which
    /// case no local server is needed anyway.
    static func portOf(styleURL: URL?) -> UInt16 {
        guard let url = styleURL, url.host == "127.0.0.1", let p = url.port,
              p > 0, p <= Int(UInt16.max) else { return 0 }
        return UInt16(p)
    }

    /// Binds `preferredPort`, or any free port when 0.
    ///
    /// Async rather than blocking: `NWListener` reports its assigned port only once it
    /// is ready, and the pack cannot be created until the URL is known.
    func start(preferredPort: UInt16 = 0) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                     port: NWEndpoint.Port(rawValue: preferredPort)
                                                        ?? .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [styleJSON] connection in
            connection.start(queue: .global(qos: .utility))
            // Read the request head BEFORE responding. Answering and closing
            // immediately races the client's write and can reset the connection —
            // Android's server carries the same note for the same reason.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let body = Data(styleJSON.utf8)
                let head = """
                    HTTP/1.1 200 OK\r
                    Content-Type: application/json\r
                    Content-Length: \(body.count)\r
                    Connection: close\r
                    \r

                    """
                connection.send(content: Data(head.utf8) + body,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The state handler fires repeatedly and from the listener's own queue, and
            // resuming a continuation twice traps — so the box, not a captured flag.
            let once = ContinuationOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.finish(.success(()))
                case .failed(let error), .waiting(let error):
                    // `waiting` is where a taken port lands, and it would otherwise sit
                    // there for ever rather than telling the caller anything.
                    once.finish(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .utility))
        }

        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}


/// Resumes a continuation at most once, from any queue.
///
/// `NWListener`'s state handler is called for every transition — `.waiting` then
/// `.ready`, `.ready` then `.cancelled` — and a continuation resumed twice traps.
private final class ContinuationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        switch result {
        case .success:            pending.resume()
        case .failure(let error): pending.resume(throwing: error)
        }
    }
}
