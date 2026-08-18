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
}
