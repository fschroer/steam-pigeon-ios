import Foundation

/// One reconstructed flight sample, mirroring the locator's `FlightArchive::FlightSample`.
struct FlightSample: Equatable {
    /// uint32 on the wire; milliseconds since the locator armed.
    let timestampMs: Int
    let altitudeM: Float
    let accel: Vec3f
    let gyro: Vec3f
    let latRad: Double
    let lonRad: Double
}

/// Metadata for a single archived flight record, mirroring `FlightMetadataRecord`.
struct FlightRecordMetadata: Equatable, Identifiable {
    /// Archive slot, 0-based — the number the flight list shows and the byte the
    /// `flightDataRequest` carries.
    let position: Int
    /// Seconds since the Unix epoch, from the locator's GPS-disciplined clock. 0 for
    /// a record written with no fix, which is why the list can show a record with no date.
    let timestampS: UInt32
    let apogeeM: Float
    /// uint16 on the wire.
    let flightTimeMs: Int

    var id: Int { position }

    /// Wall-clock launch time, or nil when the locator had no fix.
    var date: Date? {
        timestampS > 0 ? Date(timeIntervalSince1970: TimeInterval(timestampS)) : nil
    }
}

/// Transfer progress, as the flight-profile screen reads it.
struct FlightTransferProgress: Equatable {
    var transferId = 0
    var packetCount = 0
    var totalSamples = 0
    var receivedCount = 0
    var complete = false
    /// The locator answered with `packet_count == 0`: this archive slot holds no
    /// samples. Distinct from "still loading" — one resolves by waiting and the other
    /// never does, and a chart that spins forever is how that used to read.
    var noData = false
}

/// Receive side of the FlightData reliable-transfer protocol.
///
/// Ported from Android's `FlightDataRepository`, which is the reference implementation
/// (ADR-0016). It tracks which packets have arrived, decompresses each payload, keeps
/// the XOR parity frames so a single lost packet in a group of four can be
/// reconstructed without a retransmit, and builds the bitmap acknowledgement the
/// locator uses to decide what to send next.
///
/// **An instance, where Android has a singleton `object`.** Nothing about the protocol
/// wants global state, and `LinkViewModel` already owns every other piece of link
/// state; a singleton here would be a second place for a stale transfer to survive a
/// screen. No behaviour differs.
final class FlightDataRepository {

    // MARK: - Published-through state

    private(set) var metadata: [FlightRecordMetadata] = []
    private(set) var samples: [FlightSample] = []
    private(set) var progress = FlightTransferProgress()

    // MARK: - Transfer state, reset by beginTransfer()

    private var transferId = 0
    private var packetCount = 0
    private var totalSamples = 0

    /// While true every incoming packet is refused. Set by `cancelTransfer()` when the
    /// user leaves the chart mid-transfer, so late-arriving LoRa packets cannot
    /// repopulate a repository that has just been cleared. Cleared by `beginTransfer()`.
    private var draining = false

    private var received = [Bool](repeating: false, count: FlightDataSizes.maxPackets)
    /// Raw compressed payloads, kept for parity recovery. nil until packet i arrives.
    private var payloads = [[UInt8]?](repeating: nil, count: FlightDataSizes.maxPackets)
    private var samplesByPacket = [[FlightSample]?](repeating: nil, count: FlightDataSizes.maxPackets)

    /// The locator XORs each group of four data payloads into one parity payload.
    private static let parityGroupSize = 4
    private static let parityGroupCount = FlightDataSizes.maxPackets / parityGroupSize

    /// The parity payload **exactly as the sender computed it**, never mutated.
    ///
    /// Android accumulates received member payloads into this same buffer and then
    /// XORs the received members back out during recovery. Both orders cancel only
    /// while every member arrives *before* the parity frame — a member retransmitted
    /// after it is XORed in once and out once against a buffer that already contains
    /// the sender's parity, and the recovered packet comes out as garbage that
    /// `decodePayload` accepts. Keeping the sender's frame untouched and recovering as
    /// `parity XOR (received members)` is the same arithmetic with no order to get
    /// wrong. **This is a fix Android wants too** — see `docs/UI_PARITY.md`.
    private var parityPayloads = [[UInt8]?](repeating: nil, count: parityGroupCount)

    // Transfer-health diagnostics, reset per transfer.
    private var parityRecoveredCount = 0
    private var duplicateCount = 0
    private var missingLogged = [Bool](repeating: false, count: FlightDataSizes.maxPackets)

    // MARK: - Lifecycle

    /// Reset all transfer state for a new record request.
    func beginTransfer() {
        draining = false
        transferId = 0
        packetCount = 0
        totalSamples = 0
        received = [Bool](repeating: false, count: FlightDataSizes.maxPackets)
        payloads = [[UInt8]?](repeating: nil, count: FlightDataSizes.maxPackets)
        samplesByPacket = [[FlightSample]?](repeating: nil, count: FlightDataSizes.maxPackets)
        parityPayloads = [[UInt8]?](repeating: nil, count: Self.parityGroupCount)
        parityRecoveredCount = 0
        duplicateCount = 0
        missingLogged = [Bool](repeating: false, count: FlightDataSizes.maxPackets)
        samples = []
        progress = FlightTransferProgress()
    }

    /// Cancel the current transfer and refuse anything further for it.
    func cancelTransfer() {
        beginTransfer()
        draining = true
    }

    func clearMetadata() { metadata = [] }

    // MARK: - Inbound

    /// Parse a `flightMetadata` frame (MsgType 8) into the flight list.
    ///
    /// The locator only writes non-zero records, so a zero timestamp is an empty slot
    /// and is dropped rather than listed as a flight from 1970.
    @discardableResult
    func onFlightMetadata(_ frame: [UInt8]) -> Bool {
        guard frame.count >= WireProtocol.headerSize + FlightDataSizes.flightMetadataPayloadSize
        else { return false }

        var records: [FlightRecordMetadata] = []
        var o = WireProtocol.headerSize
        for i in 0..<FlightDataSizes.metadataRecordCount {
            guard let timestampS = Bytes.u32(frame, o),
                  let apogeeM = Bytes.f32(frame, o + 4),
                  let flightTimeMs = Bytes.u16(frame, o + 8) else { return false }
            o += FlightDataSizes.metadataRecordSize

            if timestampS > 0 {
                records.append(FlightRecordMetadata(position: i,
                                                    timestampS: timestampS,
                                                    apogeeM: apogeeM,
                                                    flightTimeMs: Int(flightTimeMs)))
            }
        }

        metadata = records
        return true
    }

    /// Handle a `flightData` frame (MsgType 10).
    ///
    /// - Returns: the ACK payload to send back, or nil when there is nothing to
    ///   acknowledge (a stale, refused or undecodable packet).
    func onFlightData(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= FlightDataSizes.flightDataHeaderSize else { return nil }

        let o = WireProtocol.headerSize
        guard let rxTransferId = Bytes.u16(frame, o),
              let packetIndex = Bytes.u16(frame, o + 2),
              let rxPacketCount = Bytes.u16(frame, o + 4),
              let rxTotalSamples = Bytes.u32(frame, o + 6) else { return nil }

        // packet_count == 0 is the locator's "no data for this record" marker: a
        // header-only frame. There is nothing to ACK; surface it and stop.
        if rxPacketCount == 0 {
            if draining || rxTransferId == 0 { return nil }
            if Int(rxTransferId) != transferId {
                beginTransfer()
                transferId = Int(rxTransferId)
            }
            packetCount = 0
            progress.transferId = transferId
            progress.packetCount = 0
            progress.totalSamples = 0
            progress.receivedCount = 0
            progress.complete = true
            progress.noData = true
            return nil
        }

        guard acceptTransferHeader(Int(rxTransferId), Int(rxPacketCount), Int(rxTotalSamples))
        else { return nil }

        let index = Int(packetIndex)
        guard index < packetCount else { return nil }

        if received[index] {
            duplicateCount += 1
            return ackPayload()          // re-ACK: the locator missed our last one
        }

        let payload = Array(frame[FlightDataSizes.flightDataHeaderSize...])
        guard let decoded = Self.decodePayload(payload) else { return nil }

        payloads[index] = payload
        samplesByPacket[index] = decoded
        received[index] = true

        tryRecoverMissingPackets()
        logNewGaps()
        publishSamples()
        return ackPayload()
    }

    /// Handle a `flightDataParity` frame (MsgType 11) — the XOR of one group's payloads.
    func onFlightDataParity(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= FlightDataSizes.flightDataHeaderSize else { return nil }

        let o = WireProtocol.headerSize
        guard let rxTransferId = Bytes.u16(frame, o),
              let groupIndex = Bytes.u16(frame, o + 2),
              let rxPacketCount = Bytes.u16(frame, o + 4),
              let rxTotalSamples = Bytes.u32(frame, o + 6) else { return nil }

        guard acceptTransferHeader(Int(rxTransferId), Int(rxPacketCount), Int(rxTotalSamples))
        else { return nil }

        let group = Int(groupIndex)
        guard group < parityPayloads.count else { return nil }
        if parityPayloads[group] != nil { return ackPayload() }   // duplicate parity

        parityPayloads[group] = Array(frame[FlightDataSizes.flightDataHeaderSize...])

        tryRecoverMissingPackets()
        logNewGaps()
        publishSamples()
        return ackPayload()
    }

    // MARK: - Outbound

    /// The body of a `flightDataAck`: transfer_id, packet_count, then one bit per
    /// packet, LSB-first.
    ///
    /// The header and `target_locator_id` are added by `OutboundMessage.locatorDirected`
    /// — an unaddressed ack would be obeyed by every locator on the channel (ADR-0020),
    /// and Android had exactly that bug before it spliced the target in by hand.
    func ackPayload() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: FlightDataSizes.flightDataAckPayloadSize)
        out[0] = UInt8(truncatingIfNeeded: transferId)
        out[1] = UInt8(truncatingIfNeeded: transferId >> 8)
        out[2] = UInt8(truncatingIfNeeded: packetCount)
        out[3] = UInt8(truncatingIfNeeded: packetCount >> 8)
        for n in 0..<min(packetCount, FlightDataSizes.maxPackets) where received[n] {
            out[4 + n / 8] |= UInt8(1 << (n % 8))
        }
        return out
    }

    // MARK: - Private

    /// Adopt, or refuse, the transfer this packet belongs to. A changed transfer id
    /// resets everything: it is a different record.
    private func acceptTransferHeader(_ rxTransferId: Int,
                                      _ rxPacketCount: Int,
                                      _ rxTotalSamples: Int) -> Bool {
        if rxTransferId == 0 { return false }        // 0 is reserved
        if draining { return false }                 // user left the chart

        if transferId == 0 || rxTransferId != transferId {
            beginTransfer()
            transferId = rxTransferId
            packetCount = min(rxPacketCount, FlightDataSizes.maxPackets)
            totalSamples = rxTotalSamples
            progress.transferId = transferId
            progress.packetCount = packetCount
            progress.totalSamples = totalSamples
        }
        return true
    }

    /// How many samples packet `index` carries, from the transfer's own totals. The
    /// last packet of a transfer is short.
    private func expectedSampleCount(at index: Int) -> Int {
        let globalStart = index * FlightDataSizes.samplesPerPacket
        return min(max(totalSamples - globalStart, 1), FlightDataSizes.samplesPerPacket)
    }

    /// Rebuild any packet that is the only one missing from a group whose parity frame
    /// has arrived: `missing = parity XOR (every received member)`.
    private func tryRecoverMissingPackets() {
        let groups = (packetCount + Self.parityGroupSize - 1) / Self.parityGroupSize
        for g in 0..<groups {
            guard let parity = parityPayloads[g] else { continue }

            let first = g * Self.parityGroupSize
            let last = min(first + Self.parityGroupSize, packetCount)
            let missing = (first..<last).filter { !received[$0] }
            guard missing.count == 1 else { continue }   // 0: nothing to do; 2+: unrecoverable
            let target = missing[0]

            var recovered = parity
            for p in first..<last where p != target {
                guard let member = payloads[p] else { continue }
                for b in 0..<min(member.count, recovered.count) { recovered[b] ^= member[b] }
            }

            // A short last packet is XORed against a full-length parity buffer, so the
            // recovered payload carries the sender's zero padding after the real
            // samples. Decoding that would append duplicate samples, so the count the
            // transfer header implies is what is decoded.
            guard let decoded = Self.decodePayload(recovered,
                                                   maxSamples: expectedSampleCount(at: target))
            else { continue }

            payloads[target] = recovered
            samplesByPacket[target] = decoded
            received[target] = true
            parityRecoveredCount += 1
        }
    }

    /// Note each genuinely-missing packet once. A gap *below* the highest index
    /// received is a loss parity could not cover, so the locator must retransmit it;
    /// indices above it simply have not arrived yet.
    private func logNewGaps() {
        var maxReceived = -1
        for i in 0..<packetCount where received[i] { maxReceived = i }
        guard maxReceived > 0 else { return }
        for i in 0..<maxReceived where !received[i] && !missingLogged[i] {
            missingLogged[i] = true
        }
    }

    /// Reassemble every packet held so far, in order. Gaps are simply absent — the
    /// chart draws a partial transfer as it streams.
    private func publishSamples() {
        var all: [FlightSample] = []
        var receivedCount = 0
        for i in 0..<packetCount where received[i] {
            receivedCount += 1
            if let s = samplesByPacket[i] { all.append(contentsOf: s) }
        }
        samples = all
        progress.receivedCount = receivedCount
        progress.complete = receivedCount == packetCount
    }

    /// Decompress one FlightData payload. Mirrors `FlightProfileCodec::UnpackSamples`.
    ///
    /// The first sample is stored whole in a 48-byte header; every later one is a
    /// 24-byte delta chained off it — except latitude and longitude, which are offsets
    /// from the packet's own base rather than from the previous sample.
    ///
    /// - Parameter maxSamples: stop after this many. Used for a parity-recovered
    ///   payload, whose length is the parity buffer's rather than the packet's.
    static func decodePayload(_ payload: [UInt8], maxSamples: Int? = nil) -> [FlightSample]? {
        guard payload.count >= FlightDataSizes.compressedHeaderSize else { return nil }

        var o = 0
        guard let baseTimestampMs = Bytes.u32(payload, o),
              let baseAltitudeM = Bytes.f32(payload, o + 4),
              let baseAccel = Vec3f.read(payload, o + 8),
              let baseGyro = Vec3f.read(payload, o + 20),
              let baseLatRad = Bytes.f64(payload, o + 32),
              let baseLonRad = Bytes.f64(payload, o + 40) else { return nil }
        o += FlightDataSizes.compressedHeaderSize

        var samples = [FlightSample(timestampMs: Int(baseTimestampMs),
                                    altitudeM: baseAltitudeM,
                                    accel: baseAccel,
                                    gyro: baseGyro,
                                    latRad: baseLatRad,
                                    lonRad: baseLonRad)]

        var prevTimestampMs = Int(baseTimestampMs)
        var prevAltitudeM = baseAltitudeM
        var prevAccel = baseAccel
        var prevGyro = baseGyro

        while o + FlightDataSizes.compressedDeltaSize <= payload.count {
            if let cap = maxSamples, samples.count >= cap { break }

            guard let dTimestampMs = Bytes.i16(payload, o),
                  let dAlt = Bytes.i16(payload, o + 2),
                  let dAccelX = Bytes.i16(payload, o + 4),
                  let dAccelY = Bytes.i16(payload, o + 6),
                  let dAccelZ = Bytes.i16(payload, o + 8),
                  let dGyroX = Bytes.i16(payload, o + 10),
                  let dGyroY = Bytes.i16(payload, o + 12),
                  let dGyroZ = Bytes.i16(payload, o + 14),
                  let dLatScaled = Bytes.u32(payload, o + 16),
                  let dLonScaled = Bytes.u32(payload, o + 20) else { return nil }
            o += FlightDataSizes.compressedDeltaSize

            let timestampMs = prevTimestampMs + Int(dTimestampMs)
            let altitudeM = prevAltitudeM + Float(dAlt) / 10
            let accel = Vec3f(x: prevAccel.x + Float(dAccelX) / 10,
                              y: prevAccel.y + Float(dAccelY) / 10,
                              z: prevAccel.z + Float(dAccelZ) / 10)
            let gyro = Vec3f(x: prevGyro.x + Float(dGyroX) / 10,
                             y: prevGyro.y + Float(dGyroY) / 10,
                             z: prevGyro.z + Float(dGyroZ) / 10)

            // Position deltas are signed 32-bit scaled radians, relative to the
            // packet's absolute base — not to the previous sample.
            let latRad = baseLatRad + Double(Int32(bitPattern: dLatScaled)) / FlightDataSizes.latLonScale
            let lonRad = baseLonRad + Double(Int32(bitPattern: dLonScaled)) / FlightDataSizes.latLonScale

            samples.append(FlightSample(timestampMs: timestampMs,
                                        altitudeM: altitudeM,
                                        accel: accel,
                                        gyro: gyro,
                                        latRad: latRad,
                                        lonRad: lonRad))

            prevTimestampMs = timestampMs
            prevAltitudeM = altitudeM
            prevAccel = accel
            prevGyro = gyro
        }

        return samples
    }
}
