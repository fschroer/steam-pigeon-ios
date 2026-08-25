import Foundation

/// The locator's persistent settings, as `LocatorCfgChgRequest` carries them.
///
/// Wire form is the firmware's `LocatorRocketSettings`, which both firmwares
/// `static_assert` at **45**:
///
///     6  target_locator_id u32   (ADR-0020, prepended by OutboundMessage)
///     10 deployment_ch1..4 mode u8 ×4
///     14 launch_detect_altitude u16   ← RESERVED (ADR-0028)
///     16 drogue_primary_deploy_delay u8 | 17 drogue_backup_deploy_delay u8
///     18 main_primary_deploy_altitude u16 | 20 main_backup_deploy_altitude u16
///     22 deploy_signal_duration u8   ← RESERVED (ADR-0028) | 23 lora_channel u8
///     24 device_name char[20]
///     44 nose_axis u8
///
/// `nose_axis` is last, AFTER the name, because the firmware appended it so every
/// existing field kept its offset — the receiver reads `lora_channel` by offset to
/// follow a channel change (ADR-0011), and that offset must not move.
///
/// **The two reserved slots stay on the wire and are not fields of this struct.** The
/// locator keeps its own values for both; see `reservedLaunchDetectAltitudeM`.
///
/// **The whole struct is sent for any change.** That is what makes ADR-0020's target
/// load-bearing: an unaddressed one rewrote a bystander's deployment channel modes,
/// delays and altitudes.
struct LocatorConfig: Equatable {
    var deployChannelModes: [DeployMode] = [.droguePrimary, .drogueBackup, .mainPrimary, .mainBackup]
    // launch_detect_altitude sits here on the wire and is NOT a field of this struct —
    // see `reservedLaunchDetectAltitudeM` below. Neither it nor deploy_signal_duration
    // rides in `PreLaunchData`, so the app can never learn what the locator holds for
    // either, and confirmation is whole-object equality against a config rebuilt from
    // that broadcast. Carrying them here meant every change reported "not acknowledged"
    // while the locator had accepted it.
    var droguePrimaryDelay: UInt8 = 0
    var drogueBackupDelay: UInt8 = 0
    var mainPrimaryAltitude: UInt16 = 0
    var mainBackupAltitude: UInt16 = 0
    // deploy_signal_duration sits here on the wire; see above.
    var loraChannel: Int = 0
    var deviceName: String = ""
    var noseAxis: NoseAxis = .auto

    /// Bytes of `RocketPersistentSettings` — `sizeof(LocatorSettings) - 6 - 4`.
    static let payloadSize = 35

    /// Offset of `lora_channel` within the payload. The receiver reads the byte at this
    /// offset out of the relayed frame to follow a channel change (ADR-0011), so it may
    /// not move while that `offsetof` stands.
    static let loraChannelOffset = 13

    /// ⚠️ **The two reserved slots — ADR-0028, "the app does not transmit a setting it
    /// cannot read back".**
    ///
    /// `launch_detect_altitude` and `deploy_signal_duration` still occupy their places
    /// on the wire, because removing them would move `lora_channel` and change
    /// `sizeof(LocatorSettings)` from the 45 that three firmware `static_assert`s pin —
    /// and with no version negotiation, all three binaries could then only ever be
    /// flashed together. **The locator keeps its own values for both** and no longer
    /// adopts what arrives here.
    ///
    /// The filler is the **firmware defaults, deliberately not zero**: a locator running
    /// firmware from before ADR-0028 still adopts whatever arrives in these slots, and
    /// for it zero would mean launch detected at 0 m AGL — true on the pad — and a pyro
    /// signal held for 0 s, a charge that never fires. The defaults leave such a locator
    /// exactly where it already is, which is what makes the app safe to ship ahead of
    /// the firmware. They can become zeros once no locator predating it is in service.
    ///
    /// They must match Android's `LocatorConfigWire.RESERVED_*` byte for byte.
    ///
    /// **Correcting what this file used to say:** the USB-C console never set either
    /// field either — `UserInteraction`'s config save assigns eight fields by name and
    /// neither is among them. So these are not "a silent reset of something the console
    /// configured"; both fields are now simply fixed at their defaults on every device,
    /// which ADR-0028 records as a real reduction in capability.
    static let reservedLaunchDetectAltitudeM: UInt16 = 30        // metres
    static let reservedDeploySignalDurationTenths: UInt8 = 10    // tenths of a second

    /// Everything after `target_locator_id`, which `OutboundMessage.locatorDirected`
    /// prepends. 35 bytes: 6 header + 4 target + 35 = the asserted 45.
    var payload: [UInt8] {
        var out: [UInt8] = []
        for i in 0..<4 {
            let mode = deployChannelModes.indices.contains(i) ? deployChannelModes[i] : .unused
            out.append(mode.rawValue)
        }
        out += le16(Self.reservedLaunchDetectAltitudeM)   // reserved — locator keeps its own
        out.append(droguePrimaryDelay)
        out.append(drogueBackupDelay)
        out += le16(mainPrimaryAltitude)
        out += le16(mainBackupAltitude)
        out.append(Self.reservedDeploySignalDurationTenths)  // reserved — locator keeps its own
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
            droguePrimaryDelay: m.droguePrimaryDelay,
            drogueBackupDelay: m.drogueBackupDelay,
            mainPrimaryAltitude: m.mainPrimaryAltitude,
            mainBackupAltitude: m.mainBackupAltitude,
            loraChannel: Int(m.channel),
            deviceName: m.deviceName,
            // Read back rather than remembered: the whole struct is sent, so a field
            // the app did not read would be reset the next time anything else changed.
            noseAxis: m.noseAxis)
    }
}
