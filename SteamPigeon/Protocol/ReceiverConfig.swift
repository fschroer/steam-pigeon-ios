import Foundation

/// The receiver's settable configuration.
///
/// Wire form for `ReceiverCfgChgRequest` is the firmware's `ReceiverSettings`:
/// header 6 + `lora_channel` u8 + `device_name[20]`. Receiver-directed, so it carries
/// no target — there is no locator involved (ADR-0020).
struct ReceiverConfig: Equatable {
    var channel: Int = 0
    var deviceName: String = ""

    /// Channels the radio offers. The firmware sweeps 0…63 (`kSurveyChannelCount`).
    static let channelRange = 0...63

    /// `lora_channel` then the NUL-padded name, exactly as `ReceiverSettings` lays it out.
    var payload: [UInt8] {
        var out: [UInt8] = [UInt8(clamping: channel)]
        var name = [UInt8](repeating: 0, count: WireProtocol.deviceNameLength)
        for (i, b) in Array(deviceName.utf8).prefix(WireProtocol.deviceNameLength).enumerated() {
            name[i] = b
        }
        out += name
        return out
    }
}

/// How a config change is going, app-side.
///
/// Mirrors Android's `LocatorMessageState`. It is not a wire value here — nothing
/// receives it — it is what the Update button reads to label itself, and the reason
/// the button says something other than "Update" is the whole point: a config change
/// that silently did nothing is the failure this reports.
enum ConfigMessageState: Equatable {
    case idle
    case sendRequested
    case sent
    case ackUpdated
    case sendFailure
    case notAcknowledged

    /// The Update button's label. Android's exact wording.
    var buttonLabel: String {
        switch self {
        case .idle:             return "Update"
        case .sendRequested,
             .sent:             return "Updating"
        case .ackUpdated:       return "Updated"
        case .sendFailure:      return "Update failed"
        case .notAcknowledged:  return "Update not acknowledged"
        }
    }

    var isInFlight: Bool { self == .sendRequested || self == .sent }
}
