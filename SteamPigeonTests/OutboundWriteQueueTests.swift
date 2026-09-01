import XCTest
@testable import SteamPigeon

/// ADR-0033 rules. Written as the behaviors the ADR names rather than as coverage of
/// the implementation, because the defect these encode reached a user on Android and
/// is *unobservable* on iOS — CoreBluetooth discards a `.withoutResponse` write with
/// no error, no callback and no return value.
final class OutboundWriteQueueTests: XCTestCase {

    func testCeilingMatchesTheAndroidReference() {
        XCTAssertEqual(32, OutboundWriteQueue.maxQueuedChunks)
    }

    // MARK: - Fragmentation

    /// The Android bug this half fixes: chunks were written back to back with no
    /// regard for the one-operation limit, so everything after the first was refused
    /// and a fragmented message could not arrive intact.
    func testFragmentSplitsOnTheChunkBoundary() {
        let bytes = Array(UInt8(0)...UInt8(9))
        XCTAssertEqual([[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]],
                       OutboundWriteQueue.fragment(bytes, chunkSize: 4))
    }

    func testMessageThatFitsIsNotSplit() {
        let bytes: [UInt8] = [1, 2, 3]
        XCTAssertEqual([[1, 2, 3]], OutboundWriteQueue.fragment(bytes, chunkSize: 3))
        XCTAssertEqual([[1, 2, 3]], OutboundWriteQueue.fragment(bytes, chunkSize: 244))
    }

    func testFragmentReassemblesToTheOriginal() {
        let bytes = (0..<500).map { UInt8($0 % 256) }
        for size in [1, 7, 20, 244, 512] {
            let joined = OutboundWriteQueue.fragment(bytes, chunkSize: size).flatMap { $0 }
            XCTAssertEqual(bytes, joined, "chunkSize \(size)")
        }
    }

    /// `maximumWriteValueLength` is re-queried per message and could in principle come
    /// back as nonsense; a zero or negative size must not become an infinite loop.
    func testNonPositiveChunkSizeIsClamped() {
        XCTAssertEqual([[1], [2]], OutboundWriteQueue.fragment([1, 2], chunkSize: 0))
        XCTAssertEqual([[1], [2]], OutboundWriteQueue.fragment([1, 2], chunkSize: -5))
    }

    func testEmptyMessageProducesNothing() {
        XCTAssertTrue(OutboundWriteQueue.fragment([], chunkSize: 20).isEmpty)
        var q = OutboundWriteQueue()
        XCTAssertTrue(q.enqueue([], chunkSize: 20))
        XCTAssertTrue(q.isEmpty)
    }

    // MARK: - Admission

    /// **All-or-nothing.** Admitting fragments until the ceiling is hit would put half
    /// a message on the wire, and the receiver frames some messages by exact length
    /// *before* checking their CRC — so a half-message desynchronises its framer
    /// rather than failing a check.
    func testMessageThatDoesNotFitIsRefusedWhole() {
        var q = OutboundWriteQueue()
        let thirty = (0..<30).map { UInt8($0) }
        XCTAssertTrue(q.enqueue(thirty, chunkSize: 1))       // 30 chunks, fits
        XCTAssertEqual(30, q.count)

        // 3 more would exceed 32. None of them may be admitted.
        XCTAssertFalse(q.enqueue([1, 2, 3], chunkSize: 1))
        XCTAssertEqual(30, q.count, "a refused message must leave nothing behind")

        // Exactly filling the ceiling is still allowed.
        XCTAssertTrue(q.enqueue([1, 2], chunkSize: 1))
        XCTAssertEqual(32, q.count)
    }

    func testFullQueueRefusesEvenASingleChunk() {
        var q = OutboundWriteQueue()
        XCTAssertTrue(q.enqueue((0..<32).map { UInt8($0) }, chunkSize: 1))
        XCTAssertFalse(q.enqueue([99], chunkSize: 1))
        XCTAssertEqual(32, q.count)
    }

    // MARK: - Draining

    func testDrainsInTheOrderMessagesWereHandedOver() {
        var q = OutboundWriteQueue()
        XCTAssertTrue(q.enqueue([1, 2, 3, 4], chunkSize: 2))   // [1,2] [3,4]
        XCTAssertTrue(q.enqueue([9], chunkSize: 2))            // [9]
        XCTAssertEqual([1, 2], q.dequeue())
        XCTAssertEqual([3, 4], q.dequeue())
        XCTAssertEqual([9], q.dequeue())
        XCTAssertNil(q.dequeue())
        XCTAssertTrue(q.isEmpty)
    }

    /// Draining frees the ceiling again — the bound is on what is waiting, not on how
    /// much has ever been sent.
    func testSpaceIsReclaimedAsTheQueueDrains() {
        var q = OutboundWriteQueue()
        XCTAssertTrue(q.enqueue((0..<32).map { UInt8($0) }, chunkSize: 1))
        XCTAssertFalse(q.enqueue([99], chunkSize: 1))
        _ = q.dequeue()
        XCTAssertTrue(q.enqueue([99], chunkSize: 1))
    }

    // MARK: - Clearing

    /// A queued write belongs to the connection it was made on. Carrying it into the
    /// next one is ADR-0011's late-delivery hazard.
    func testClearDiscardsEverythingAndReportsHowMuch() {
        var q = OutboundWriteQueue()
        XCTAssertTrue(q.enqueue([1, 2, 3, 4, 5], chunkSize: 2))  // 3 chunks
        XCTAssertEqual(3, q.clear())
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(0, q.clear(), "clearing an empty queue discards nothing")
    }

    func testQueueIsUsableAgainAfterClearing() {
        var q = OutboundWriteQueue()
        XCTAssertTrue(q.enqueue([1, 2, 3], chunkSize: 1))
        q.clear()
        XCTAssertTrue(q.enqueue([7, 8], chunkSize: 1))
        XCTAssertEqual([7], q.dequeue())
        XCTAssertEqual([8], q.dequeue())
    }
}
