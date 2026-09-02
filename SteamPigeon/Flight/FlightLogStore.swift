import Foundation

/// Where app flight logs live on disk, and everything done to them afterwards.
///
/// **App-private storage, not the Files app.** ADR-0030 decision 7 puts the logs somewhere
/// they are deletable from exactly one place — the App Flight Logs screen — so the list on
/// that screen is the truth about what exists. The ADR explicitly rejected writing into
/// shared storage: it would make the files visible without an export step, at the cost of a
/// list that goes stale whenever someone tidies a folder on their laptop, and of nothing to
/// say when a log the user is reading vanishes underneath them.
///
/// On iOS that means **Application Support**, and deliberately NOT `Documents` with
/// `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` — that pair is the exact
/// iOS spelling of the alternative the ADR turned down. Export covers the same need
/// deliberately instead of incidentally, through the share sheet.
///
/// Ported from Android's `data/FlightLogStore.kt`, whose `FileProvider` half has no
/// counterpart here: a `UIActivityViewController` shares a file URL directly.
final class FlightLogStore {

    static let dirName = "flight_logs"
    static let maxViewRows = 5_000

    private let root: URL

    /// - Parameter container: the base directory. Defaults to Application Support; tests
    ///   pass a temporary directory of their own.
    init(container: URL? = nil) {
        let base = container ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                              in: .userDomainMask,
                                                              appropriateFor: nil,
                                                              create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appendingPathComponent(Self.dirName, isDirectory: true)
    }

    private var dir: URL {
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root,
                                                     withIntermediateDirectories: true)
        }
        return root
    }

    // MARK: - Listing, reading, deleting

    /// Every stored log, newest first.
    ///
    /// Ordered by the capture time parsed out of the name, and NOT by file mtime: mtime
    /// moves when a log is appended to, so an old flight still open through a long recovery
    /// would sort above a newer one that had already closed.
    ///
    /// **Both platforms sorted on the whole filename until 2026-09-01, which is not the
    /// same thing.** The name is `<locator>_<date>_<time>`, so that sort is locator-major
    /// and only chronological *within* one airframe: `Twist_Lock_5` from yesterday listed
    /// above `Kestrel` from today. Found here, on the simulator, with two injected logs —
    /// the iOS port had mirrored Android's sort faithfully, including the defect, and two
    /// locators on one screen is what made it visible. Fixed on Android first
    /// (`FlightLogStore.ordered`) and then mirrored here.
    func list() -> [FlightLogFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.lastPathComponent.hasSuffix(FlightLog.fileExtension) }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey,
                                                               .contentModificationDateKey])
                return FlightLogFile(name: url.lastPathComponent,
                                     sizeBytes: Int64(values?.fileSize ?? 0),
                                     modified: values?.contentModificationDate ?? .distantPast)
            }
            .sortedNewestFirst()
    }

    /// A log's rows for on-screen viewing, capped at `maxRows`.
    ///
    /// The cap is a display limit, never a transfer limit — ``url(for:)`` always hands over
    /// the whole file. A log left open through a long recovery can reach tens of thousands
    /// of rows, and rendering all of them into a list would stall the screen to show what
    /// nobody scrolls to. The truncation is reported so the screen can say the file has
    /// more in it rather than quietly ending early.
    func read(_ name: String, maxRows: Int = maxViewRows) -> FlightLogContents {
        guard let url = fileURL(for: name),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return FlightLogContents(rows: [], totalRows: 0, truncated: false) }

        var all = text.components(separatedBy: .newlines)
        if all.last?.isEmpty == true { all.removeLast() }
        let shown = Array(all.prefix(maxRows))
        return FlightLogContents(rows: shown, totalRows: all.count,
                                 truncated: all.count > shown.count)
    }

    @discardableResult
    func delete(_ name: String) -> Bool {
        guard let url = fileURL(for: name) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// The file itself, for the share sheet. Nil when it is gone.
    func url(for name: String) -> URL? { fileURL(for: name) }

    /// Resolves a name to a file inside ``dir``, refusing anything that escapes it.
    ///
    /// The names this store issues are safe by construction, but they round-trip through
    /// screen state before coming back here, and a path check at the point of use costs
    /// nothing next to being wrong about that.
    private func fileURL(for name: String) -> URL? {
        let url = dir.appendingPathComponent(name)
        guard url.deletingLastPathComponent().standardizedFileURL.path
                == dir.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    // MARK: - Writing

    /// A ``FlightLogRecorder/Sink`` backed by a real file.
    func makeSink() -> any FlightLogRecorder.Sink { FileSink(dir: dir) }

    /// Appends run on a serial background queue. The recorder is driven from the packet
    /// handler on the main actor, and a write per second from there is main-thread I/O
    /// however small it is. Serial rather than concurrent because rows must land in the
    /// order they were offered, and a concurrent queue would reorder them under exactly the
    /// load that makes a log worth having.
    ///
    /// `open` is deliberately synchronous: it happens once per flight, and its result
    /// decides whether the recorder believes it is recording at all. That verdict cannot be
    /// delivered later without the recorder having already acted on a guess.
    private final class FileSink: FlightLogRecorder.Sink {
        private let dir: URL
        private let queue = DispatchQueue(label: "com.steampigeon.flightlog.write")
        private var handle: FileHandle?

        init(dir: URL) { self.dir = dir }

        func open(fileName: String) -> Bool {
            closeQuietly()
            let url = dir.appendingPathComponent(fileName)
            let header = FlightLog.csvHeader + "\n"
            guard FileManager.default.createFile(atPath: url.path,
                                                 contents: Data(header.utf8)),
                  let h = try? FileHandle(forWritingTo: url)
            else { return false }
            try? h.seekToEnd()
            handle = h
            return true
        }

        /// Written and synced on every batch, which is once per second.
        ///
        /// A buffer left unflushed loses whatever it holds if the app is killed — and an
        /// app killed mid-flight is not hypothetical: it is the backgrounded case this log
        /// is most wanted for, and losing the tail would lose the part nobody saw. One sync
        /// per second is nothing next to that.
        func append(_ rows: [String]) {
            guard let h = handle, !rows.isEmpty else { return }
            let blob = Data(rows.joined(separator: "\n").appending("\n").utf8)
            queue.async {
                do {
                    try h.write(contentsOf: blob)
                    try h.synchronize()
                } catch {
                    // A failed append must not take the flight down. The rows are lost;
                    // the ones already on disk are not.
                }
            }
        }

        func close() {
            let h = handle
            handle = nil
            // Queued behind any pending appends, so the last rows offered before the close
            // reach the file rather than racing it.
            queue.async { try? h?.close() }
        }

        private func closeQuietly() {
            let h = handle
            handle = nil
            queue.async { try? h?.close() }
        }
    }
}

/// One stored log, as the list screen needs it.
struct FlightLogFile: Identifiable, Equatable {
    let name: String
    let sizeBytes: Int64
    let modified: Date

    var id: String { name }

    /// The locator name and launch time, recovered from the filename.
    ///
    /// Parsed rather than stored alongside because the filename is the only thing
    /// guaranteed to exist for every log — a sidecar index would need to stay in step with
    /// a directory the recorder writes to from another queue, and be rebuilt whenever it
    /// did not.
    var locatorName: String {
        let stem = stemOfName
        // Drop the time then the date, both underscore-separated suffixes.
        var parts = stem.components(separatedBy: "_")
        guard parts.count > 2 else { return FlightLog.unnamedLocator }
        parts.removeLast()
        parts.removeLast()
        let name = parts.joined(separator: "_")
        return name.isEmpty ? FlightLog.unnamedLocator : name
    }

    /// The `YYYY-MM-DD_HHmmss` half of the name, or nil when it does not parse.
    ///
    /// The sort key, and deliberately NOT ``capturedAt``: that one falls back to the raw
    /// stem so the screen always has something to show, and a stem beginning with a letter
    /// sorts ABOVE every real date in a descending order — so reusing it would put
    /// unparseable files first, which is the opposite of what the fallback is for.
    /// Fixed-width and zero-padded, so lexicographic order is chronological order and no
    /// date parsing is needed to sort.
    var captureKey: String? {
        let parts = stemOfName.components(separatedBy: "_")
        guard parts.count >= 3 else { return nil }
        let time = parts[parts.count - 1]
        let date = parts[parts.count - 2]
        guard date.count == 10, time.count == 6 else { return nil }
        return "\(date)_\(time)"
    }

    /// `YYYY-MM-DD HH:MM:SS`, or the raw stem if it does not parse.
    var capturedAt: String {
        guard let key = captureKey else { return stemOfName }
        let date = key.prefix(10)
        let time = key.suffix(6)
        let h = time.prefix(2)
        let m = time.dropFirst(2).prefix(2)
        let s = time.dropFirst(4).prefix(2)
        return "\(date) \(h):\(m):\(s)"
    }

    private var stemOfName: String {
        name.hasSuffix(FlightLog.fileExtension)
            ? String(name.dropLast(FlightLog.fileExtension.count))
            : name
    }
}

extension Array where Element == FlightLogFile {
    /// Newest first, by capture time; anything whose name does not parse sorts last.
    ///
    /// The Swift half of Android's `FlightLogStore.ordered`, lifted out for the same
    /// reason: this is the part that was wrong for a day while the directory listing
    /// around it was fine.
    ///
    /// A log with an unparseable name did not come from this app's recorder. It still has
    /// to land somewhere deterministic rather than interleaving with real dates, so it goes
    /// to the end, ordered by name for stability.
    func sortedNewestFirst() -> [FlightLogFile] {
        sorted { a, b in
            let ka = a.captureKey ?? ""
            let kb = b.captureKey ?? ""
            return ka == kb ? a.name > b.name : ka > kb
        }
    }
}

/// A log's rows, and whether the screen is seeing all of them.
struct FlightLogContents: Equatable {
    let rows: [String]
    let totalRows: Int
    let truncated: Bool
}
