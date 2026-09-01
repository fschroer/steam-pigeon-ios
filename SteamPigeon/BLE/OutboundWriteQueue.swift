import Foundation

/// The ADR-0033 outbound write queue, as pure logic.
///
/// **A write the transport refuses is not a refusal from the device.** On Android
/// that lesson arrived as a visible bug: the stack allows one GATT operation in
/// flight, refuses the next write outright, and `sendData` passed the refusal up as
/// a send failure — so pressing **Search N channels** while the 2 s channel poll had
/// a write outstanding reported *"No response from the receiver … update its
/// firmware"* instantly, with nothing transmitted, about a receiver that was healthy
/// and current.
///
/// **iOS is exposed to the same hazard with the diagnostic surface removed.**
/// CoreBluetooth's `writeValue` returns `Void`, so there is no refusal to mishandle
/// — but a `.withoutResponse` write issued while `canSendWriteWithoutResponse` is
/// `false` is **silently discarded by the framework**. No error, no callback, no
/// return value. Android at least handed us a boolean to get wrong; here the message
/// simply never happens. `BluetoothTransport.send` wrote in a bare loop with no
/// regard for that flag until this landed.
///
/// Deliberately free of CoreBluetooth so the rules can be tested without hardware,
/// as `ConnectionHealthMonitor` is for ADR-0012. What lives here is everything that
/// does not need a radio: fragmentation, the all-or-nothing admission rule, the
/// ceiling, and FIFO order. What lives in the transport is the flag, the
/// `peripheralIsReady` callback, and the stall guard.
struct OutboundWriteQueue {

    /// Ceiling on queued-but-unsent chunks. Android's `MAX_QUEUED_WRITES`, and the
    /// same reasoning: a link that has stopped draining must not grow this without
    /// bound, and past the ceiling a caller is at least told.
    static let maxQueuedChunks = 32

    private(set) var chunks: [[UInt8]] = []

    var isEmpty: Bool { chunks.isEmpty }
    var count: Int { chunks.count }

    init() {}

    /// Split `bytes` the way the link currently allows.
    ///
    /// Separate from `enqueue` because the chunk size is a property of the live
    /// connection — iOS negotiates the MTU after `didConnect` and never reports a
    /// change, so the transport re-queries it per message and hands the result in.
    /// Never caching that is an ADR-0016 invariant.
    static func fragment(_ bytes: [UInt8], chunkSize: Int) -> [[UInt8]] {
        let size = max(1, chunkSize)
        guard bytes.count > size else { return bytes.isEmpty ? [] : [bytes] }
        var out: [[UInt8]] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            out.append(Array(bytes[offset..<end]))
            offset = end
        }
        return out
    }

    /// Admit one whole message, or none of it.
    ///
    /// **All-or-nothing is the point.** Admitting fragments until the ceiling is hit
    /// would put the first half of a message on the wire and drop the rest, which
    /// reaches the receiver as a malformed frame rather than as the absence of one —
    /// and the receiver frames some messages by exact length before checking their
    /// CRC, so a half-message desynchronises its framer instead of failing a check.
    ///
    /// Returns `false` when the message does not fit, which is the caller's cue to
    /// report a send failure. That is now the *only* thing a send failure means.
    mutating func enqueue(_ bytes: [UInt8], chunkSize: Int) -> Bool {
        let pieces = Self.fragment(bytes, chunkSize: chunkSize)
        guard !pieces.isEmpty else { return true }
        guard chunks.count + pieces.count <= Self.maxQueuedChunks else { return false }
        chunks.append(contentsOf: pieces)
        return true
    }

    /// Take the next chunk to write, in the order messages were handed over.
    mutating func dequeue() -> [UInt8]? {
        chunks.isEmpty ? nil : chunks.removeFirst()
    }

    /// Drop everything, returning how much was discarded so the caller can log it.
    ///
    /// Called when the link goes away. A queued write belongs to the connection it
    /// was made on; carrying it into the next one is the late-delivery hazard
    /// ADR-0011 documents — a request firing minutes later, out of the flow that
    /// queued it, against whatever the receiver has since been pointed at.
    @discardableResult
    mutating func clear() -> Int {
        let discarded = chunks.count
        chunks.removeAll(keepingCapacity: true)
        return discarded
    }
}
