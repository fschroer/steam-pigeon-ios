import Foundation

/// Decides what reaches a flight log and when, holding no platform types, no clock and no
/// tasks.
///
/// Extracted the way `ChannelMoveRunner` was, and for the same reason: the sequencing is
/// the part that can be wrong — what is kept, what is discarded, which signal ends a file —
/// and none of it is testable while it sits inside `LinkViewModel` with a transport in
/// scope. Everything with a side effect goes through ``Sink``.
///
/// ## The pre-roll, and why nothing is written before a launch
///
/// Records offered before a launch go into a ring pruned to `preRoll`, and the ring lives
/// in memory. A session spent connecting, arming, changing channels and disarming again
/// therefore leaves *nothing* on disk — not a file that is deleted afterwards, but no file
/// at all. A launch is the only thing that opens a file, and the ring is what makes the two
/// seconds before it available once one does.
///
/// ## What ends a log
///
/// Landing does not. It is recorded as an event and the file stays open, because the walk-in
/// to recover the rocket is when link quality matters most and is exactly the window the
/// operator cannot watch. A log ends on a ``LogCloseReason``: the locator disarmed, the
/// receiver or locator changed under it, the app stopping, or the next launch — each of
/// which either ends the flight's relevance or makes the following rows describe something
/// else.
///
/// Ported from Android's `data/FlightLogRecorder.kt` (ADR-0030).
final class FlightLogRecorder {

    /// Where rows go. Implemented against real files by `FlightLogStore`.
    protocol Sink {
        /// Begins a file and writes ``FlightLog/csvHeader``.
        ///
        /// Returns false if it could not — a full disk, a revoked directory. The recorder
        /// then stays idle rather than believing it is recording, so the next launch tries
        /// again instead of dropping rows into nothing.
        func open(fileName: String) -> Bool
        func append(_ rows: [String])
        func close()
    }

    /// Two seconds, as asked, which at 1 Hz is the two frames before the launch frame.
    /// Enough to carry the last on-pad reading of RSSI, noise floor and pad-alert state
    /// into the file — the state the rocket left the pad in.
    static let defaultPreRoll: TimeInterval = 2

    private let sink: any Sink
    private let preRollSpan: TimeInterval

    private var preRoll: [FlightLogRecord] = []
    private var openLaunch: Date?

    /// The zone is fixed for the life of a recorder; settable so tests can pin UTC.
    var timeZone: TimeZone = .current

    init(sink: any Sink, preRoll: TimeInterval = defaultPreRoll) {
        self.sink = sink
        self.preRollSpan = preRoll
    }

    /// True while a file is open and rows are reaching it.
    var isRecording: Bool { openLaunch != nil }

    /// Offer a record. Buffered while idle, written while recording.
    ///
    /// The ring is pruned against the newest record offered rather than a wall clock, so it
    /// holds the last `preRoll` *of received data*. During a dropout it therefore keeps the
    /// last frames heard instead of ageing them out into an empty buffer — the frames
    /// before a signal was lost being the ones worth having.
    func offer(_ record: FlightLogRecord) {
        if let t0 = openLaunch {
            sink.append([FlightLog.row(record, t0: t0, zone: timeZone)])
            return
        }
        preRoll.append(record)
        while let first = preRoll.first,
              record.timestamp.timeIntervalSince(first.timestamp) > preRollSpan {
            preRoll.removeFirst()
        }
    }

    /// A launch was detected: open a file and flush the pre-roll into it.
    ///
    /// A launch while a log is already open closes that one first. Two flights cannot share
    /// a file — the second would read as the first continuing, and `elapsed_s` would be
    /// measured from the wrong zero.
    @discardableResult
    func onLaunch(at timestamp: Date, locatorName: String, header: String) -> Bool {
        if isRecording { close(at: timestamp, reason: .newLaunch) }
        let name = FlightLog.fileName(locatorName: locatorName, at: timestamp, zone: timeZone)
        guard sink.open(fileName: name) else {
            // Keep the pre-roll: the next launch, or a retry, still has it.
            return false
        }
        openLaunch = timestamp
        // Stamped at the oldest row the file will contain so the timestamps are monotonic
        // from the first line — a reader sorting by time must not have to special-case the
        // header row sitting two seconds in the future.
        let openedAt = preRoll.first?.timestamp ?? timestamp
        var rows = [FlightLog.row(.event(.init(timestamp: openedAt,
                                               event: .sessionOpened,
                                               detail: header)),
                                  t0: timestamp, zone: timeZone)]
        rows += preRoll.map { FlightLog.row($0, t0: timestamp, zone: timeZone) }
        rows.append(FlightLog.row(.event(.init(timestamp: timestamp,
                                               event: .launchDetected,
                                               detail: locatorName)),
                                  t0: timestamp, zone: timeZone))
        preRoll.removeAll()
        sink.append(rows)
        return true
    }

    /// Ends an open log. A no-op when nothing is open, so callers need no guard.
    func close(at timestamp: Date, reason: LogCloseReason) {
        guard let t0 = openLaunch else { return }
        sink.append([FlightLog.row(.event(.init(timestamp: timestamp,
                                                event: .sessionClosed,
                                                detail: reason.label)),
                                   t0: t0, zone: timeZone)])
        sink.close()
        openLaunch = nil
    }

    /// Drop buffered pre-roll without writing it.
    ///
    /// For the moment the data stops describing the same thing — a different locator
    /// connected, the receiver retuned — where carrying the previous subject's frames into
    /// the next launch's pre-roll would put two rockets in one file. Does not touch an open
    /// log; that is ``close(at:reason:)``'s job.
    func discardPreRoll() { preRoll.removeAll() }
}
