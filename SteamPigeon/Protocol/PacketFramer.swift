import Foundation

/// How many bytes the next frame occupies, or why that cannot be decided yet.
///
/// Android encodes all three of these as `Int`, using `Int.MAX_VALUE` for "unknown"
/// and `MAX_PACKET_SIZE` for "not enough bytes yet". Those are distinct outcomes with
/// opposite handling — resync versus wait — and this project has already been bitten
/// once by a sentinel that silently read as a real value (`kNoiseFloorUnknown`, which
/// arrived as −32768 and poisoned the noise-floor baseline). They are separate cases
/// here so neither can be mistaken for a length.
enum FrameLength: Equatable {
    /// The frame occupies exactly this many bytes.
    case known(Int)
    /// The header is not fully buffered yet — wait for more bytes, do not resync.
    case needMoreBytes
    /// Not a message type this app frames — drop one byte and resync.
    case unframeable
}

/// Reassembles Steam Pigeon packets from a byte stream.
///
/// BLE delivers notifications in arbitrary chunks: one notification may carry part of
/// a packet, several packets, or a packet boundary in the middle. On iOS this is *more*
/// variable than on Android, because the MTU is negotiated after connect and cannot be
/// pinned (ADR-0016), so a frame that arrived whole yesterday may arrive split today.
/// The framer therefore holds an accumulator and re-evaluates it on every append.
///
/// Ported from the Android `extractPackets` / `computeExpectedPacketLength` in
/// `BluetoothService.kt`, which per ADR-0009 is the reference implementation.
///
/// **Framing runs before parsing, before authentication, and before anything knows
/// whose packet it is** — so it derives no state. Android learned this the hard way:
/// armed state was once derived here from the message type alone, and with two
/// locators powered, the armed one's `TelemetryData` and the disarmed one's
/// `PreLaunchData` flipped the flag against each other at the broadcast rate.
struct PacketFramer {

    /// Bytes received but not yet formed into a complete frame.
    private(set) var buffer: [UInt8] = []

    /// Frames dropped because their CRC did not verify. The receiver reports its own
    /// bad-frame count separately; this is the app-side view of the same problem, and
    /// a rising count is the signal that ended a debugging loop more than once.
    private(set) var badFrameCount = 0

    /// A rejected frame, captured so a bad-CRC count can be explained rather than
    /// guessed at. A count alone says only "something did not verify" — which of the
    /// several possible causes it was needs the bytes.
    struct Reject {
        /// The msgType byte the framer read from the candidate header.
        let msgTypeByte: UInt8
        /// The length the framer computed and then CRC-checked.
        let claimedLength: Int
        /// The frame as received, capped. Whole for anything receiver-sized; a
        /// prefix for the big relayed broadcasts.
        let bytes: [UInt8]
        /// What the sender put in the header.
        let embeddedCrc: UInt16
        /// What we computed over `claimedLength` bytes.
        let computedCrc: UInt16

        /// The length at which the sender's CRC actually verifies, if any.
        ///
        /// Scans every plausible prefix, not just a couple either side. A match well
        /// short of the expected length means the sender computed its CRC over a
        /// SHORTER message than we expect — which is not corruption at all, but a
        /// wire-format version difference: the device is running firmware from before
        /// a field was added. Those need completely different responses, and the
        /// narrow ±2 scan could not tell them apart.
        var matchesAtOtherLength: Int? {
            guard bytes.count >= WireProtocol.headerSize else { return nil }
            for n in WireProtocol.headerSize...bytes.count where n != claimedLength {
                if PacketFramer.computeCrc(Array(bytes.prefix(n))) == embeddedCrc { return n }
            }
            return nil
        }

        /// Indices > 0 where a system-id byte is followed by a plausible message type.
        /// **This is the truncation signature.** If the sender's write was cut short,
        /// the framer fills the shortfall from whatever came next — and what comes
        /// next begins with a header. A clean frame has no second header inside it.
        var embeddedHeaders: [Int] {
            var found: [Int] = []
            for i in 1..<max(1, bytes.count - 1)
            where bytes[i] == WireProtocol.systemId && MsgType(rawValue: bytes[i + 1]) != nil {
                found.append(i)
            }
            return found
        }

        /// Byte indices that differ from the previous reject of the same type. With a
        /// repeating message, what varies is the evidence — a constant sender CRC over
        /// varying bytes has to be explained by whichever bytes those are.
        var differsFromPreviousAt: [Int] = []

        /// If changing exactly ONE byte would make the CRC verify, which byte and to
        /// what. A CRC-16 disagreement says only "these bytes are not those bytes";
        /// this says *where*, which usually names the field and therefore the cause.
        /// Truncation lands on the last bytes, a stale accumulator on its own field.
        var singleByteFix: (index: Int, expected: UInt8, actual: UInt8)? {
            guard bytes.count == claimedLength else { return nil }   // need the whole frame
            for i in 0..<bytes.count where i != 4 && i != 5 {        // crc field is excluded
                let actual = bytes[i]
                for candidate in UInt8.min...UInt8.max where candidate != actual {
                    var trial = bytes
                    trial[i] = candidate
                    if PacketFramer.computeCrc(trial) == embeddedCrc {
                        return (i, candidate, actual)
                    }
                }
            }
            return nil
        }

        var summary: String {
            let name = MsgType(rawValue: msgTypeByte).map(String.init(describing:))
                ?? "unknown(\(msgTypeByte))"
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            let crcs = String(format: "crc got=%04x calc=%04x", embeddedCrc, computedCrc)
            let alt = matchesAtOtherLength.map {
                " MATCHES-AT-LEN=\($0) (sender used a \($0)-byte message)"
            } ?? ""
            var marks = ""
            let heads = embeddedHeaders
            if !heads.isEmpty {
                marks += "\n    TRUNCATION? header bytes inside frame at \(heads)"
            }
            if !differsFromPreviousAt.isEmpty {
                marks += "\n    differs from previous at \(differsFromPreviousAt)"
            }
            var fix = ""
            if let f = singleByteFix {
                fix = String(format: "\n    ONE-BYTE: index %d is %02x, CRC wants %02x",
                             f.index, f.actual, f.expected)
            }
            return "\(name) len=\(claimedLength) \(crcs)\(alt)\(marks)\(fix)\n    [\(hex)]"
        }
    }

    /// Most recent rejects, newest last. Capped — this is a diagnostic, not a log.
    private(set) var recentRejects: [Reject] = []
    private static let maxRejectsKept = 12
    private static let rejectCaptureBytes = 64

    init() {}

    /// Feed one BLE notification (or any chunk) in; get back every complete,
    /// CRC-verified frame it completed, in order.
    mutating func append<S: Sequence>(_ incoming: S) -> [[UInt8]] where S.Element == UInt8 {
        buffer.append(contentsOf: incoming)
        return drain()
    }

    /// Discard everything buffered. Use on disconnect — a half-frame from a previous
    /// connection must not be completed by bytes from the next one.
    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private mutating func drain() -> [[UInt8]] {
        var frames: [[UInt8]] = []

        while true {
            guard buffer.count >= WireProtocol.headerSize else { break }

            // Resync: the stream must start on a system-id byte.
            guard buffer[0] == WireProtocol.systemId else {
                buffer.removeFirst()
                continue
            }

            let expected: Int
            switch Self.expectedPacketLength(buffer) {
            case .needMoreBytes:
                return frames                      // wait; do NOT consume
            case .unframeable:
                buffer.removeFirst()
                continue
            case .known(let n):
                // A length outside the protocol's bounds means we are not actually
                // looking at a header — resync rather than trusting it.
                guard n >= WireProtocol.headerSize, n <= WireProtocol.maxPacketSize else {
                    buffer.removeFirst()
                    continue
                }
                expected = n
            }

            guard buffer.count >= expected else { break }   // frame still incomplete

            let frame = Array(buffer[0..<expected])
            guard Self.verifyCrc(frame) else {
                badFrameCount += 1
                var reject = Reject(
                    msgTypeByte: frame[1],
                    claimedLength: expected,
                    bytes: Array(frame.prefix(Self.rejectCaptureBytes)),
                    embeddedCrc: Self.embeddedCrc(frame) ?? 0,
                    computedCrc: Self.computeCrc(frame)
                )
                if let prev = recentRejects.last(where: { $0.msgTypeByte == frame[1] }) {
                    reject.differsFromPreviousAt = zip(prev.bytes, reject.bytes).enumerated()
                        .filter { $0.element.0 != $0.element.1 }
                        .map(\.offset)
                }
                recentRejects.append(reject)
                if recentRejects.count > Self.maxRejectsKept { recentRejects.removeFirst() }
                buffer.removeFirst()                        // resync one byte on
                continue
            }

            frames.append(frame)
            buffer.removeFirst(expected)
        }

        return frames
    }

    // MARK: - Length

    /// Exact on-wire length of the frame starting at index 0.
    static func expectedPacketLength(_ bytes: [UInt8]) -> FrameLength {
        guard bytes.count >= WireProtocol.headerSize else { return .needMoreBytes }
        guard let msgType = MsgType(rawValue: bytes[1]) else { return .unframeable }

        switch msgType {
        case .preLaunchData:  return .known(WireProtocol.headerSize + WireProtocol.prelaunchMessagePayloadSize)
        case .telemetryData:  return .known(WireProtocol.headerSize + WireProtocol.telemetryMessagePayloadSize)
        case .deploymentTest: return .known(WireProtocol.headerSize + WireProtocol.deploymentTestPayloadSize)
        case .flightMetadata: return .known(WireProtocol.headerSize + FlightDataSizes.flightMetadataPayloadSize)
        case .flightEvents:   return .known(WireProtocol.headerSize + WireProtocol.flightEventsPayloadSize)
        case .receiverInfo:   return .known(WireProtocol.headerSize + WireProtocol.receiverInfoPayloadSize)
        case .versionInfo:    return .known(WireProtocol.headerSize + WireProtocol.versionInfoPayloadSize)
        case .channelSurvey:  return .known(WireProtocol.headerSize + WireProtocol.channelSurveyPayloadSize)
        // Fixed length, and framed for the same reason `receiverInfo` is: it is the
        // only way the app learns a run's progress, and an unframed one would be
        // resynced past a byte at a time — surviving on the CRC gate, but dropping
        // the message the whole search reports through.
        case .locatorSearchResult:
            return .known(WireProtocol.headerSize + WireProtocol.locatorSearchResultPayloadSize)

        case .flightData:
            // Variable-length. Compute the EXACT length from the packet header so the
            // framer delimits precisely: consuming "the rest of the buffer" breaks the
            // moment packets are bursted or split, because the CRC covers the full
            // frame length and would never match.
            return flightDataPacketLength(bytes)

        case .flightDataParity:
            // Parity frames always carry the full payload buffer → fixed size.
            return .known(FlightDataSizes.flightDataParitySize)

        // Types the app sends but never receives, plus `startup`, which the locator
        // does send. Android frames none of them and resyncs past them instead; the
        // CRC gate makes that correct, only slightly wasteful. Framing `startup`
        // would be a behavior change, and ADR-0016 puts those on Android first.
        case .startup, .locatorCfgChgRequest, .receiverCfgChgRequest, .armRequest,
             .disarmRequest, .flightMetadataRequest, .flightDataRequest, .flightDataAck,
             .deploymentTestRequest, .receiverInfoRequest, .versionRequest,
             .channelSurveyRequest, .channelSurveyCancelRequest, .padAlertSnoozeRequest,
             .locatorSearchRequest:
            return .unframeable
        }
    }

    /// Exact on-wire length of a `flightData` packet, from its own header.
    static func flightDataPacketLength(_ buffer: [UInt8]) -> FrameLength {
        guard buffer.count >= FlightDataSizes.flightDataHeaderSize else { return .needMoreBytes }
        let o = WireProtocol.headerSize

        let packetIndex = Int(buffer[o + 2]) | (Int(buffer[o + 3]) << 8)
        let packetCount = Int(buffer[o + 4]) | (Int(buffer[o + 5]) << 8)

        // packet_count == 0 is the locator's "no data for this record" marker:
        // a header-only frame with no payload.
        if packetCount == 0 { return .known(FlightDataSizes.flightDataHeaderSize) }

        let totalSamples = Int(buffer[o + 6])
            | (Int(buffer[o + 7]) << 8)
            | (Int(buffer[o + 8]) << 16)
            | (Int(buffer[o + 9]) << 24)

        // The last packet of a transfer carries fewer than a full set of samples.
        let globalStart = packetIndex * FlightDataSizes.samplesPerPacket
        let count = min(max(totalSamples - globalStart, 1), FlightDataSizes.samplesPerPacket)

        return .known(FlightDataSizes.flightDataHeaderSize
                      + FlightDataSizes.compressedHeaderSize
                      + (count - 1) * FlightDataSizes.compressedDeltaSize)
    }

    // MARK: - CRC

    /// Message CRC over the frame with the crc field itself skipped, seeded 0xFFFF.
    /// Mirrors `Communication::ValidateCRC`.
    static func computeCrc(_ frame: [UInt8]) -> UInt16 {
        var crc = Crc16.accumulate(Crc16.initialSeed, frame[0..<4])
        if frame.count > 6 {
            crc = Crc16.accumulate(crc, frame[6...])
        }
        return crc
    }

    /// The crc the sender put in the header (bytes 4..5, little-endian).
    static func embeddedCrc(_ frame: [UInt8]) -> UInt16? {
        guard frame.count >= WireProtocol.headerSize else { return nil }
        return UInt16(frame[4]) | (UInt16(frame[5]) << 8)
    }

    static func verifyCrc(_ frame: [UInt8]) -> Bool {
        guard let embedded = embeddedCrc(frame) else { return false }
        return embedded == computeCrc(frame)
    }
}
