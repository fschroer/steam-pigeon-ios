import Foundation

/// Message types on the Steam Pigeon wire.
///
/// A shared enum in the triad — it must agree with `Communication::MsgType` in the
/// locator's and receiver's `MessageProtocol.hpp` and with the Android `MsgType`.
/// Existing coverage differences are tracked in
/// [#5](https://github.com/fschroer/steam-pigeon-locator/issues/5).
///
/// **This copy takes the receiver's full space**, which is the only complete one,
/// rather than reproducing the gaps in the other two. The gaps are coverage, not
/// conflict — every value defined in more than one place carries the same meaning,
/// verified across all three at locator `b870d95`:
///
/// | value | locator FW | receiver FW | Android |
/// |---|---|---|---|
/// | `startup` (0)            | yes | yes | **absent** |
/// | 1–14, 17–22              | yes | yes | yes |
/// | `receiverInfo*` (15, 16) | **absent** | yes | yes |
///
/// Both gaps are defensible: 15/16 are app↔receiver only, so the locator has no use
/// for them, and the app never originates a `startup`. Claiming the whole space here
/// is what stops a future message silently colliding — the same reasoning the locator
/// firmware gives for reserving 20/21 that it never sends.
enum MsgType: UInt8, CaseIterable {

    /// Locator→app at power-up (`sizeof(StartupMessage) == 74`).
    ///
    /// Defined so the value is claimed, but **deliberately not framed** — see
    /// `PacketFramer.expectedPacketLength`, which treats it exactly as Android does.
    /// Framing it would be a behavior change, and per ADR-0016 those land on Android
    /// first, never here first.
    case startup = 0

    /// App→locator: update locator configuration (carries `RocketPersistentSettings`).
    case locatorCfgChgRequest = 1
    /// App→receiver: update receiver configuration.
    case receiverCfgChgRequest = 2
    /// App→locator: arm. Addressed (ADR-0020).
    case armRequest = 3
    /// App→locator: disarm. Addressed (ADR-0020).
    case disarmRequest = 4

    /// Locator→app, unsolicited, while disarmed. Authenticated (ADR-0006).
    case preLaunchData = 5
    /// Locator→app, unsolicited, while armed. Authenticated (ADR-0006).
    case telemetryData = 6

    /// App→locator: list the archived flights. Addressed.
    case flightMetadataRequest = 7
    /// Locator→app: one record per archive slot.
    case flightMetadata = 8
    /// App→locator: send one flight profile. Addressed.
    case flightDataRequest = 9
    /// Locator→app: profile data, multiple variable-length packets.
    case flightData = 10
    /// Locator→app: parity packet for reconstructing one lost data packet.
    case flightDataParity = 11
    /// App→locator: bitmap acknowledgement of received packets. Addressed.
    case flightDataAck = 12

    /// App→locator: run a deployment test. Addressed.
    case deploymentTestRequest = 13
    /// Locator→app: deployment-test countdown.
    case deploymentTest = 14

    /// App→receiver: report current channel and name. **Receiver-only** — the
    /// locator firmware does not define this value.
    case receiverInfoRequest = 15
    /// Receiver→app: current LoRa channel, name, noise floor, bad-frame count.
    /// **Receiver-only.**
    case receiverInfo = 16

    /// App→locator: both firmware versions. Addressed.
    case versionRequest = 17
    /// Locator→app via receiver, which appends its own version.
    case versionInfo = 18
    /// Locator→app: per-record flight event summary.
    case flightEvents = 19

    /// App→receiver: sweep the band (ADR-0019 tier 3). No locator involved; the
    /// locator reserves the value but never sends it.
    case channelSurveyRequest = 20
    /// Receiver→app: per-channel occupancy.
    case channelSurvey = 21

    /// App→locator: suppress the prepped-and-disarmed alert for N minutes.
    /// Addressed — snoozing somebody else's rocket would be a safety hole.
    case padAlertSnoozeRequest = 22

    /// App→receiver: listen for locators on named channels (ADR-0029). No locator
    /// involved; the locator firmware reserves the value and implements nothing.
    case locatorSearchRequest = 23
    /// Receiver→app: one result per channel searched, plus a terminator.
    ///
    /// **Streamed**, unlike the survey's single response: a whole-band run is up to ~90 s,
    /// and one answer at the end would leave the app with a dead progress bar and no
    /// way to show a hit the moment it happens.
    case locatorSearchResult = 24
}
