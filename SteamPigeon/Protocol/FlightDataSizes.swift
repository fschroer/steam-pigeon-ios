import Foundation

/// Sizes owned by the flight-data transfer path (Android: `FlightDataRepository.kt`).
enum FlightDataSizes {

    /// 9 archive slots × `sizeof(FlightMetadataRecord) == 10`.
    ///
    /// 9, was 10: the locator's `FlightSample` grew 80 → 88 B for ARCHIVE_VERSION 6,
    /// so `record_count` in `Archive.hpp` dropped to 9 and the message shrank with
    /// it (96 B on the wire, 90 B of payload). This constant IS the parser's loop
    /// bound — too high and a short frame is rejected outright, too low and the
    /// trailing slots silently vanish from the flight list.
    static let flightMetadataPayloadSize = 90

    /// PacketHeader 6 + transfer_id 2 + packet_count 2 + bitmap[32].
    ///
    /// This is the body the ack **builder** produces. On the wire the send path
    /// splices in `target_locator_id`, so the firmware sees
    /// `sizeof(FlightDataAck) == 46`.
    static let flightDataAckSize = 42

    /// Transfer window: 256 packets, so the ack bitmap is 32 bytes.
    static let maxPackets = 256

    /// PacketHeader 6 + record 2 + packet_index 2 + packet_count 2 + total_samples 4.
    static let flightDataHeaderSize = WireProtocol.headerSize + 2 + 2 + 2 + 4   // 16

    /// First sample in a packet is stored whole; the rest are deltas.
    static let compressedHeaderSize = 4 + 4 + 12 + 12 + 8 + 8                   // 48
    static let compressedDeltaSize  = 2 + 2 + 6 + 6 + 4 + 4                     // 24
    static let samplesPerPacket = 8

    /// Compressed payload capacity the locator reserves per packet (C++
    /// `kPayloadSize`, `static_assert`ed at 239).
    static let flightDataPayloadCapacity = 239

    /// A parity frame always carries the full payload buffer, so unlike a data
    /// packet its on-wire size is fixed. 16 + 239 = 255 =
    /// `sizeof(FlightDataPacket)`.
    static let flightDataParitySize = flightDataHeaderSize + flightDataPayloadCapacity
}
