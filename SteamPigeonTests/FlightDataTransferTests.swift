import XCTest
@testable import SteamPigeon

/// The FlightData receive path: metadata, the delta codec, the ack bitmap and parity
/// recovery.
///
/// Android has no test for its `FlightDataRepository` — this is the first one, and it
/// exists because the two ends of this protocol cannot be exercised together without a
/// locator and a real archived flight. Every frame here is written out longhand at the
/// firmware's offsets, so a wire-layout change breaks a test rather than silently
/// decoding a flight into nonsense.
final class FlightDataTransferTests: XCTestCase {

    // MARK: - Frame builders

    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
    }
    private func le32(_ v: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
    }
    private func le64(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
    }
    private func f32(_ v: Float) -> [UInt8] { le32(v.bitPattern) }
    private func f64(_ v: Double) -> [UInt8] { le64(v.bitPattern) }
    private func i16(_ v: Int16) -> [UInt8] { le16(UInt16(bitPattern: v)) }
    private func i32(_ v: Int32) -> [UInt8] { le32(UInt32(bitPattern: v)) }

    /// `CompressedHeader`: the packet's first sample, stored whole.
    private func compressedHeader(timestampMs: UInt32 = 1_000,
                                  altitudeM: Float = 100,
                                  accel: (Float, Float, Float) = (1, 2, 3),
                                  gyro: (Float, Float, Float) = (4, 5, 6),
                                  latRad: Double = 0.7,
                                  lonRad: Double = -1.3) -> [UInt8] {
        var out = le32(timestampMs) + f32(altitudeM)
        out += f32(accel.0) + f32(accel.1) + f32(accel.2)
        out += f32(gyro.0) + f32(gyro.1) + f32(gyro.2)
        out += f64(latRad) + f64(lonRad)
        XCTAssertEqual(out.count, FlightDataSizes.compressedHeaderSize)
        return out
    }

    /// `CompressedDelta`: one later sample, chained off the previous one.
    private func compressedDelta(dtMs: Int16 = 50, dAlt: Int16 = 10,
                                 dAccel: (Int16, Int16, Int16) = (0, 0, 0),
                                 dGyro: (Int16, Int16, Int16) = (0, 0, 0),
                                 dLatScaled: Int32 = 0, dLonScaled: Int32 = 0) -> [UInt8] {
        var out = i16(dtMs) + i16(dAlt)
        out += i16(dAccel.0) + i16(dAccel.1) + i16(dAccel.2)
        out += i16(dGyro.0) + i16(dGyro.1) + i16(dGyro.2)
        out += i32(dLatScaled) + i32(dLonScaled)
        XCTAssertEqual(out.count, FlightDataSizes.compressedDeltaSize)
        return out
    }

    /// A payload of `samples` samples: one header plus `samples - 1` deltas.
    private func payload(samples: Int, altitudeStep: Int16 = 10,
                         baseAltitude: Float = 100) -> [UInt8] {
        var out = compressedHeader(altitudeM: baseAltitude)
        for _ in 1..<max(samples, 1) { out += compressedDelta(dAlt: altitudeStep) }
        return out
    }

    private func dataFrame(_ type: MsgType = .flightData,
                           transferId: UInt16 = 7,
                           index: UInt16,
                           packetCount: UInt16,
                           totalSamples: UInt32,
                           payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [WireProtocol.systemId, type.rawValue, 0, 0, 0, 0]
        frame += le16(transferId) + le16(index) + le16(packetCount) + le32(totalSamples)
        XCTAssertEqual(frame.count, FlightDataSizes.flightDataHeaderSize)
        return frame + payload
    }

    /// The parity frame the locator sends per group of four: the XOR of every member
    /// payload, over the full payload buffer it reserves.
    private func parityFrame(transferId: UInt16 = 7, group: UInt16,
                             packetCount: UInt16, totalSamples: UInt32,
                             members: [[UInt8]]) -> [UInt8] {
        var parity = [UInt8](repeating: 0, count: FlightDataSizes.flightDataPayloadCapacity)
        for member in members {
            for (i, b) in member.enumerated() where i < parity.count { parity[i] ^= b }
        }
        return dataFrame(.flightDataParity, transferId: transferId, index: group,
                         packetCount: packetCount, totalSamples: totalSamples, payload: parity)
    }

    private func metadataFrame(_ records: [(timestampS: UInt32, apogee: Float, flightMs: UInt16)])
        -> [UInt8] {
        var frame: [UInt8] = [WireProtocol.systemId, MsgType.flightMetadata.rawValue, 0, 0, 0, 0]
        for i in 0..<FlightDataSizes.metadataRecordCount {
            let r = i < records.count ? records[i] : (timestampS: UInt32(0), apogee: Float(0),
                                                      flightMs: UInt16(0))
            frame += le32(r.timestampS) + f32(r.apogee) + le16(r.flightMs)
        }
        XCTAssertEqual(frame.count,
                       WireProtocol.headerSize + FlightDataSizes.flightMetadataPayloadSize)
        return frame
    }

    // MARK: - Metadata

    func testMetadataListsOnlyWrittenSlots() {
        let repo = FlightDataRepository()
        XCTAssertTrue(repo.onFlightMetadata(metadataFrame([
            (1_770_000_000, 921.5, 60_000),
            (0, 0, 0),                                   // empty slot, between two used ones
            (1_770_100_000, 312.25, 42_000),
        ])))

        XCTAssertEqual(repo.metadata.map(\.position), [0, 2])
        XCTAssertEqual(repo.metadata[0].apogeeM, 921.5, accuracy: 0.001)
        XCTAssertEqual(repo.metadata[0].flightTimeMs, 60_000)
        XCTAssertEqual(repo.metadata[1].position, 2)
        // A slot with no timestamp is an unwritten slot, not a flight from 1970.
        XCTAssertNotNil(repo.metadata[0].date)
    }

    func testShortMetadataFrameIsRejected() {
        let repo = FlightDataRepository()
        let short = Array(metadataFrame([(1, 1, 1)]).dropLast())
        XCTAssertFalse(repo.onFlightMetadata(short))
        XCTAssertTrue(repo.metadata.isEmpty)
    }

    // MARK: - Codec

    func testDecodesBaseSampleThenDeltas() throws {
        var bytes = compressedHeader(timestampMs: 2_000, altitudeM: 50,
                                     accel: (1, 2, 3), gyro: (4, 5, 6),
                                     latRad: 0.75, lonRad: -1.25)
        bytes += compressedDelta(dtMs: 50, dAlt: 25, dAccel: (10, -10, 5),
                                 dGyro: (0, 0, 0), dLatScaled: 1_000, dLonScaled: -2_000)
        bytes += compressedDelta(dtMs: 50, dAlt: -5)

        let samples = try XCTUnwrap(FlightDataRepository.decodePayload(bytes))
        XCTAssertEqual(samples.count, 3)

        XCTAssertEqual(samples[0].timestampMs, 2_000)
        XCTAssertEqual(samples[0].altitudeM, 50, accuracy: 0.0001)
        XCTAssertEqual(samples[0].latRad, 0.75, accuracy: 1e-12)

        // Deltas are tenths, and the kinematic fields chain off the previous sample.
        XCTAssertEqual(samples[1].timestampMs, 2_050)
        XCTAssertEqual(samples[1].altitudeM, 52.5, accuracy: 0.0001)
        XCTAssertEqual(samples[1].accel.x, 2, accuracy: 0.0001)
        XCTAssertEqual(samples[1].accel.y, 1, accuracy: 0.0001)

        // Position is an offset from the packet's BASE, not from the previous sample,
        // and the scale is radians × 1e7.
        XCTAssertEqual(samples[1].latRad, 0.75 + 1_000 / 1e7, accuracy: 1e-12)
        XCTAssertEqual(samples[1].lonRad, -1.25 - 2_000 / 1e7, accuracy: 1e-12)
        XCTAssertEqual(samples[2].latRad, 0.75, accuracy: 1e-12, "second delta is zero lat")

        XCTAssertEqual(samples[2].timestampMs, 2_100)
        XCTAssertEqual(samples[2].altitudeM, 52, accuracy: 0.0001)
    }

    func testPayloadShorterThanOneHeaderIsRejected() {
        XCTAssertNil(FlightDataRepository.decodePayload([UInt8](repeating: 0, count: 47)))
    }

    // MARK: - Acknowledgement

    func testAckCarriesTheTransferAndABitPerReceivedPacket() {
        let repo = FlightDataRepository()
        let p = payload(samples: 8)
        _ = repo.onFlightData(dataFrame(transferId: 0x1234, index: 0, packetCount: 12,
                                        totalSamples: 96, payload: p))
        guard let bytes = repo.onFlightData(dataFrame(transferId: 0x1234, index: 9,
                                                      packetCount: 12, totalSamples: 96,
                                                      payload: p)) else {
            return XCTFail("packet 9 was not acknowledged")
        }

        XCTAssertEqual(bytes.count, FlightDataSizes.flightDataAckPayloadSize)
        XCTAssertEqual(bytes[0], 0x34)
        XCTAssertEqual(bytes[1], 0x12)
        XCTAssertEqual(bytes[2], 12)
        XCTAssertEqual(bytes[3], 0)
        XCTAssertEqual(bytes[4], 0b0000_0001, "packet 0 sets bit 0 of the first bitmap byte")
        XCTAssertEqual(bytes[5], 0b0000_0010, "packet 9 sets bit 1 of the second")

        // Addressed on the way out (ADR-0020), and the whole frame is what the firmware
        // sizes at 46 bytes.
        let frame = OutboundMessage.locatorDirected(.flightDataAck, targetLocatorId: 0xABCD,
                                                    payload: bytes)
        XCTAssertEqual(frame?.count,
                       FlightDataSizes.flightDataAckSize + WireProtocol.targetLocatorIdSize)
    }

    func testDuplicatePacketIsReAcknowledgedRatherThanCountedTwice() {
        let repo = FlightDataRepository()
        let frame = dataFrame(index: 0, packetCount: 4, totalSamples: 32,
                              payload: payload(samples: 8))
        _ = repo.onFlightData(frame)
        let before = repo.samples.count
        XCTAssertNotNil(repo.onFlightData(frame), "a duplicate is still acknowledged")
        XCTAssertEqual(repo.samples.count, before, "and does not duplicate its samples")
        XCTAssertEqual(repo.progress.receivedCount, 1)
    }

    // MARK: - Transfer assembly

    func testProgressCompletesWhenEveryPacketHasArrived() {
        let repo = FlightDataRepository()
        for i in 0..<4 {
            _ = repo.onFlightData(dataFrame(index: UInt16(i), packetCount: 4, totalSamples: 32,
                                            payload: payload(samples: 8)))
        }
        XCTAssertTrue(repo.progress.complete)
        XCTAssertEqual(repo.progress.receivedCount, 4)
        XCTAssertEqual(repo.samples.count, 32)
    }

    func testANewTransferIdResetsEverything() {
        let repo = FlightDataRepository()
        _ = repo.onFlightData(dataFrame(transferId: 1, index: 0, packetCount: 4,
                                        totalSamples: 32, payload: payload(samples: 8)))
        _ = repo.onFlightData(dataFrame(transferId: 2, index: 0, packetCount: 2,
                                        totalSamples: 16, payload: payload(samples: 8)))
        XCTAssertEqual(repo.progress.transferId, 2)
        XCTAssertEqual(repo.progress.packetCount, 2)
        XCTAssertEqual(repo.samples.count, 8, "the first transfer's samples are gone")
    }

    func testEmptyRecordMarkerReportsNoDataAndIsNotAcknowledged() {
        let repo = FlightDataRepository()
        let marker = dataFrame(index: 0, packetCount: 0, totalSamples: 0, payload: [])
        XCTAssertNil(repo.onFlightData(marker), "there is nothing to acknowledge")
        XCTAssertTrue(repo.progress.noData)
        XCTAssertTrue(repo.progress.complete)
    }

    func testACancelledTransferRefusesLatePackets() {
        let repo = FlightDataRepository()
        repo.cancelTransfer()
        XCTAssertNil(repo.onFlightData(dataFrame(index: 0, packetCount: 4, totalSamples: 32,
                                                 payload: payload(samples: 8))))
        XCTAssertTrue(repo.samples.isEmpty)

        // …until a new request re-opens it.
        repo.beginTransfer()
        XCTAssertNotNil(repo.onFlightData(dataFrame(index: 0, packetCount: 4, totalSamples: 32,
                                                    payload: payload(samples: 8))))
    }

    // MARK: - Parity recovery

    func testParityRebuildsTheOneMissingPacketOfAGroup() throws {
        let repo = FlightDataRepository()
        let members = (0..<4).map { payload(samples: 8, altitudeStep: Int16(10 + $0)) }

        // Packet 2 never arrives.
        for i in [0, 1, 3] {
            _ = repo.onFlightData(dataFrame(index: UInt16(i), packetCount: 4, totalSamples: 32,
                                            payload: members[i]))
        }
        XCTAssertEqual(repo.progress.receivedCount, 3)

        _ = repo.onFlightDataParity(parityFrame(group: 0, packetCount: 4, totalSamples: 32,
                                                members: members))

        XCTAssertTrue(repo.progress.complete, "parity should have completed the transfer")
        XCTAssertEqual(repo.samples.count, 32)
        // The recovered packet must decode to exactly what was sent, not to something
        // that merely has the right length.
        let expected = try XCTUnwrap(FlightDataRepository.decodePayload(members[2]))
        XCTAssertEqual(Array(repo.samples[16..<24]), expected)
    }

    /// **The ordering Android gets wrong.** A packet lost and retransmitted arrives
    /// *after* the parity frame for its group. Android XORs every data payload into the
    /// same buffer it stores the parity in, so a late member corrupts it and recovery
    /// produces garbage that the decoder happily accepts.
    func testParityStillRecoversWhenAMemberArrivesAfterTheParityFrame() throws {
        let repo = FlightDataRepository()
        let members = (0..<4).map { payload(samples: 8, altitudeStep: Int16(10 + $0)) }

        // Packets 1 and 2 are both lost, so parity can recover nothing yet.
        for i in [0, 3] {
            _ = repo.onFlightData(dataFrame(index: UInt16(i), packetCount: 4, totalSamples: 32,
                                            payload: members[i]))
        }
        _ = repo.onFlightDataParity(parityFrame(group: 0, packetCount: 4, totalSamples: 32,
                                                members: members))
        XCTAssertFalse(repo.progress.complete)

        // Packet 1 is retransmitted; packet 2 is now the only one missing.
        _ = repo.onFlightData(dataFrame(index: 1, packetCount: 4, totalSamples: 32,
                                        payload: members[1]))

        XCTAssertTrue(repo.progress.complete)
        let expected = try XCTUnwrap(FlightDataRepository.decodePayload(members[2]))
        XCTAssertEqual(Array(repo.samples[16..<24]), expected)
    }

    func testParityCannotRecoverTwoMissingPackets() {
        let repo = FlightDataRepository()
        let members = (0..<4).map { payload(samples: 8, altitudeStep: Int16(10 + $0)) }
        for i in [0, 1] {
            _ = repo.onFlightData(dataFrame(index: UInt16(i), packetCount: 4, totalSamples: 32,
                                            payload: members[i]))
        }
        _ = repo.onFlightDataParity(parityFrame(group: 0, packetCount: 4, totalSamples: 32,
                                                members: members))
        XCTAssertEqual(repo.progress.receivedCount, 2)
        XCTAssertFalse(repo.progress.complete)
    }

    /// A short last packet is XORed against a full-length parity buffer, so the
    /// recovered payload carries the sender's zero padding behind the real samples.
    /// Decoding all of it would append duplicates of the final sample.
    func testARecoveredShortPacketDecodesOnlyItsOwnSamples() throws {
        let repo = FlightDataRepository()
        // 27 samples: three full packets of 8 and a last one of 3.
        let members = [payload(samples: 8), payload(samples: 8), payload(samples: 8),
                       payload(samples: 3)]
        for i in 0..<3 {
            _ = repo.onFlightData(dataFrame(index: UInt16(i), packetCount: 4, totalSamples: 27,
                                            payload: members[i]))
        }
        _ = repo.onFlightDataParity(parityFrame(group: 0, packetCount: 4, totalSamples: 27,
                                                members: members))

        XCTAssertTrue(repo.progress.complete)
        XCTAssertEqual(repo.samples.count, 27, "the padding must not become extra samples")
        let expected = try XCTUnwrap(FlightDataRepository.decodePayload(members[3]))
        XCTAssertEqual(Array(repo.samples[24...]), expected)
    }
}
