import Foundation

/// Which deployment channel to fire, as `DeploymentTestRequest` carries it.
///
/// **`none` is not merely "nothing selected".** Sent as the channel of a request, 0 is
/// the wire value that CANCELS a running test — see the locator's `MessageProtocol.hpp`
/// and its `DeploymentTestRequest` handler. That is why the stop control and the exit
/// path both send a channel rather than a different message.
enum DeploymentTestOption: UInt8, CaseIterable, Identifiable {
    case none = 0
    case channel1 = 1
    case channel2 = 2
    case channel3 = 3
    case channel4 = 4

    var id: UInt8 { rawValue }

    /// Android renders `enumValue.name` in its dropdown, so these are the case names —
    /// `Channel1`, not "Channel 1". The same string on both platforms is the one the
    /// manual has to print.
    var label: String {
        switch self {
        case .none:     return "None"
        case .channel1: return "Channel1"
        case .channel2: return "Channel2"
        case .channel3: return "Channel3"
        case .channel4: return "Channel4"
        }
    }

    /// The channel number as the buttons say it. 0 for `none`, which never appears.
    var channelNumber: Int { Int(rawValue) }
}

/// The locator's deployment-test countdown (`MsgType.deploymentTest`), one second apart.
///
/// **This message is the only thing the app can believe about a running test.** The
/// request that starts it and the request that cancels it are both unacknowledged LoRa
/// frames; the countdown arriving is the evidence a test is live, and the countdown
/// stopping is the only evidence one has ended — whether it was canceled, fired, or the
/// link died (ADR-0027).
///
/// It is also, per ADR-0027, the receiver's transmit reference while the locator is in
/// `DeviceState::Test`: a locator counting down sends nothing else, so the receiver keys
/// its command window on this frame. Without it a cancel is queued and never forwarded —
/// found on the bench with the countdown running to zero and firing.
struct DeploymentTestCountdown: Equatable {
    /// Seconds remaining. Reaching the app as 0 would mean the test is over, but the
    /// locator simply stops sending instead.
    let secondsRemaining: Int

    static func parse(_ frame: [UInt8]) -> DeploymentTestCountdown? {
        guard frame.count >= WireProtocol.headerSize + WireProtocol.deploymentTestPayloadSize,
              let count = Bytes.u8(frame, WireProtocol.headerSize) else { return nil }
        return DeploymentTestCountdown(secondsRemaining: Int(count))
    }
}
