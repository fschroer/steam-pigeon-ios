import Foundation

/// The locator's persistent settings, as `LocatorCfgChgRequest` carries them.
///
/// Wire form is the firmware's `LocatorRocketSettings`, which both firmwares
/// `static_assert` at **45**:
///
///     6  target_locator_id u32   (ADR-0020, prepended by OutboundMessage)
///     10 deployment_ch1..4 mode u8 ×4
///     14 launch_detect_altitude u16
///     16 drogue_primary_deploy_delay u8 | 17 drogue_backup_deploy_delay u8
///     18 main_primary_deploy_altitude u16 | 20 main_backup_deploy_altitude u16
///     22 deploy_signal_duration u8 | 23 lora_channel u8
///     24 device_name char[20]
///     44 nose_axis u8
///
/// `nose_axis` is last, AFTER the name, because the firmware appended it so every
/// existing field kept its offset — the receiver reads `lora_channel` by offset to
/// follow a channel change (ADR-0011), and that offset must not move.
///
/// **The whole struct is sent for any change.** That is what makes ADR-0020's target
/// load-bearing: an unaddressed one rewrote a bystander's deployment channel modes,
/// delays and altitudes.
struct LocatorConfig: Equatable {
    var deployChannelModes: [DeployMode] = [.droguePrimary, .drogueBackup, .mainPrimary, .mainBackup]
    var launchDetectAltitude: UInt16 = LocatorConfig.launchDetectAltitudePlaceholder
    var droguePrimaryDelay: UInt8 = 0
    var drogueBackupDelay: UInt8 = 0
    var mainPrimaryAltitude: UInt16 = 0
    var mainBackupAltitude: UInt16 = 0
    var deploySignalDuration: UInt8 = LocatorConfig.deploySignalDurationPlaceholder
    var loraChannel: Int = 0
    var deviceName: String = ""
    var noseAxis: NoseAxis = .auto

    /// ⚠️ **Placeholders, not readings — and they are WRITTEN BACK to the locator.**
    ///
    /// `PreLaunchData` does not carry `launch_detect_altitude` or
    /// `deploy_signal_duration`, so the app has no way to learn what the locator
    /// actually holds; but `LocatorCfgChgRequest` sends the whole struct, so every
    /// config change — including a pure channel move — writes these two values.
    ///
    /// Android does exactly the same, with the same constants and a `// To do: remove
    /// from UI` beside them, and they must MATCH Android's: the confirmation test is
    /// whole-object equality against a config rebuilt from the next broadcast, so a
    /// different placeholder here would never compare equal and every change would
    /// report as unacknowledged.
    ///
    /// These are the firmware defaults, so on an unmodified locator this is a no-op.
    /// On one whose values were changed over the USB console it is not: a channel move
    /// silently restores 30 m and 1.0 s. Fixing it properly means carrying both fields
    /// in a broadcast, which is a firmware change and belongs in an ADR.
    static let launchDetectAltitudePlaceholder: UInt16 = 30      // metres
    static let deploySignalDurationPlaceholder: UInt8 = 10       // tenths of a second

    /// Everything after `target_locator_id`, which `OutboundMessage.locatorDirected`
    /// prepends. 35 bytes: 6 header + 4 target + 35 = the asserted 45.
    var payload: [UInt8] {
        var out: [UInt8] = []
        for i in 0..<4 {
            let mode = deployChannelModes.indices.contains(i) ? deployChannelModes[i] : .unused
            out.append(mode.rawValue)
        }
        out += le16(launchDetectAltitude)
        out.append(droguePrimaryDelay)
        out.append(drogueBackupDelay)
        out += le16(mainPrimaryAltitude)
        out += le16(mainBackupAltitude)
        out.append(deploySignalDuration)
        out.append(UInt8(clamping: loraChannel))

        var name = [UInt8](repeating: 0, count: WireProtocol.deviceNameLength)
        for (i, b) in Array(deviceName.utf8).prefix(WireProtocol.deviceNameLength).enumerated() {
            name[i] = b
        }
        out += name
        out.append(noseAxis.rawValue)
        return out
    }

    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
    }

    /// What the locator is currently believed to hold, rebuilt from a broadcast.
    ///
    /// The channel comes from the RECEIVER-appended channel, per ADR-0011 invariant 3:
    /// a received `PreLaunchData` proves the locator and receiver share that channel,
    /// so it IS the locator's current channel and is what a change is confirmed
    /// against. There is no acknowledgement message; the resumption of broadcasts on
    /// the new channel is the acknowledgement.
    static func from(_ m: PreLaunchData) -> LocatorConfig {
        LocatorConfig(
            deployChannelModes: m.deployChannelModes,
            launchDetectAltitude: launchDetectAltitudePlaceholder,
            droguePrimaryDelay: m.droguePrimaryDelay,
            drogueBackupDelay: m.drogueBackupDelay,
            mainPrimaryAltitude: m.mainPrimaryAltitude,
            mainBackupAltitude: m.mainBackupAltitude,
            deploySignalDuration: deploySignalDurationPlaceholder,
            loraChannel: Int(m.channel),
            deviceName: m.deviceName,
            // Read back rather than remembered: the whole struct is sent, so a field
            // the app did not read would be reset the next time anything else changed.
            noseAxis: m.noseAxis)
    }
}
