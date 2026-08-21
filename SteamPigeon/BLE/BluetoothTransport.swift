import Foundation
import CoreBluetooth

/// Link state, mirroring the Android `BluetoothConnectionState` closely enough to
/// compare behavior, minus the states iOS has no equivalent for (Android's adapter
/// enable/permission flow has no counterpart — iOS shows one system prompt).
enum TransportState: Equatable {
    case idle
    case unsupported
    case unauthorized
    case poweredOff
    case scanning
    case noDevicesFound
    case connecting
    case connected          // GATT link up, characteristics not yet resolved
    case ready              // notifications enabled; traffic can flow
    case disconnected
}

/// CoreBluetooth transport to the Steam Pigeon receiver.
///
/// Implements the invariants in ADR-0016, which were confirmed on real hardware by
/// `Tools/ios-ble-probe/BLEProbe.swift`. The GATT table is identical to Android's:
/// service `FFE0`, `FFE1` for outbound writes, `FFE2` for inbound notifications.
///
/// Android's `BluetoothConnectionManager` is the reference implementation, but four
/// things it relies on do not exist here, and each is handled rather than emulated:
/// MAC addresses, an explicit MTU request, connection-priority control, and a
/// foreground service.
final class BluetoothTransport: NSObject {

    // MARK: - GATT layout (confirmed on hardware)

    static let serviceUUID = CBUUID(string: "FFE0")
    /// Phone → device. [WRITE, WRITE_NO_RESPONSE]
    static let writeCharUUID = CBUUID(string: "FFE1")
    /// Device → phone. [NOTIFY]
    static let notifyCharUUID = CBUUID(string: "FFE2")

    /// Identifies this central across process restarts so iOS can hand the session
    /// back via `willRestoreState`. Must be stable — a changed key is a new central
    /// and restoration silently stops working.
    static let restoreIdentifier = "com.steampigeon.ios.central"

    // MARK: - Callbacks

    /// Complete, CRC-verified frames. Already reassembled by `PacketFramer`.
    var onFrame: (([UInt8]) -> Void)?
    var onStateChange: ((TransportState) -> Void)?
    /// Every FFE0 peripheral seen this scan, so the user can choose. Android shows a
    /// picker whenever discovery finds one or more devices; connecting to whatever
    /// answered first is wrong the moment there are two receivers at a launch.
    var onDiscover: (([CBPeripheral]) -> Void)?
    private(set) var discovered: [CBPeripheral] = []

    /// ADR-0012: send a `receiverInfoRequest`. Wired by the caller, because building
    /// that message is protocol work, not transport work.
    var onHealthProbe: (() -> Void)?
    /// Running count of frames the framer rejected on CRC. The receiver reports its
    /// own bad-frame count over the air; this is the app-side view of the same
    /// problem, and a rising count is the signal that ended more than one debugging
    /// loop on the Android side.
    var onBadFrameCount: ((Int) -> Void)?
    /// The rejected frames themselves. A count says only that something failed to
    /// verify; identifying which of several possible causes it was needs the bytes.
    var onReject: ((PacketFramer.Reject) -> Void)?

    // MARK: - State

    private(set) var state: TransportState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var framer = PacketFramer()
    private var health = ConnectionHealthMonitor()
    private var healthTimer: Timer?
    private var scanWindowTimer: Timer?

    // Transport identity is `peripheral.identifier` — iOS never exposes a MAC, so
    // Android's `macPrefix = "D8:67"` filter has no counterpart. It is **per-install**:
    // it differs on another phone and changes on reinstall, so it identifies *a
    // receiver on this install* and nothing more. Locator identity is unaffected —
    // that keys on the 32-bit `locator_id` from telemetry (ADR-0006).
    //
    // It is no longer PERSISTED. A remembered identifier existed only to reconnect
    // without asking, which is the behaviour that hid the second receiver; with the
    // picker always offered there is nothing left to remember, and a stored id that
    // nothing reads is a trap for the next reader.

    // MARK: - Lifecycle

    override init() {
        super.init()
        // The central is created HERE and not lazily on first scan. Deferring it is
        // the obvious-looking cure for "the initialiser opens hardware", and it is
        // wrong: restoration requires the central to exist by the time launch
        // finishes, because iOS calls `willRestoreState` on it during launch. Moving
        // creation to the first scan — which is driven by a view appearing — would
        // work in the foreground and silently drop every background wake, the one
        // case restoration exists for.
        //
        // The owner is constructed once, which is what makes one eager central safe.
        // Measured on 2026-08-20, iOS 26.5 simulator, by logging `LinkViewModel.init`:
        // one call at launch, and still one after opening the menu, a destination and
        // the diagnostics sheet. The two `CLLocationManager`s visible in a launch log
        // are OURS plus MapLibre's — MapLibre's is the one that never gets
        // `setDesiredAccuracy`/`setDistanceFilter` and calls `stopUpdatingLocation`
        // when authorization changes.
        //
        // State Preservation & Restoration replaces Android's foreground service.
        // iOS has no always-running equivalent: the app is *woken* for BLE events.
        // This is viable only because the receiver advertises FFE0 — background
        // scanning requires a service filter.
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    /// How long to collect before offering the choice. Android's `SCAN_DURATION_MS`.
    ///
    /// A window rather than reporting each device as it arrives: with two receivers
    /// powered up, whichever advertises first would otherwise pop a one-item list, and
    /// the second would appear under the user's thumb a moment later. Three seconds is
    /// long enough for both to be heard and short enough not to feel like a hang.
    static let scanWindow: TimeInterval = 3

    /// Scan for the receiver by **service UUID**, never by name.
    ///
    /// Name filtering works in the foreground and silently fails in the background,
    /// where a service filter is mandatory. FFE0 is advertised by default
    /// (`03 03 E0FF`) and the receiver firmware issues no `AT+UIDS`/`AT+SADV`/`AT+UADV`
    /// that would change that — so this is the one correct filter.
    ///
    /// **This never auto-connects, not even to the receiver used last.** It used to:
    /// a remembered `peripheral.identifier` was reconnected directly and the scan was
    /// skipped, which meant that with two receivers powered up the app silently took
    /// the one it had used before and never offered the other. Android has no such
    /// path — it scans for a fixed window and always raises the picker on what it
    /// found — and someone with two receivers could not reach the second one here
    /// without understanding why.
    /// Whether CoreBluetooth will accept a command at all.
    ///
    /// Every central command is gated on this. CoreBluetooth does not queue a command
    /// issued in any other state — it logs `API MISUSE: … can only accept this command
    /// while in the powered on state` and **drops it**, so an ungated call is not merely
    /// noisy, it is an action the app believes it took and did not. Reported from the
    /// phone as that log line on 2026-08-21.
    private var canCommandCentral: Bool { central.state == .poweredOn }

    /// A restored connection whose GATT session still has to be rebuilt. Set by
    /// `willRestoreState`, consumed the moment the central reports `.poweredOn`.
    private var needsRestoredDiscovery = false

    func startScan() {
        guard canCommandCentral else { return }
        // A scan already running is left alone, as Android does ("scan already in
        // progress — ignoring duplicate call"). `startScan` is reached twice at
        // launch — once from `centralManagerDidUpdateState` on poweredOn, once from
        // the view appearing — and restarting the window threw away everything the
        // first one had already found. That is a plausible cause of "sometimes only
        // one of two receivers is listed": whichever answered early was discarded, and
        // a receiver that had just advertised was in no hurry to advertise again.
        guard scanWindowTimer == nil else { return }

        state = .scanning
        // Seed with receivers ALREADY connected to this phone — including one iOS
        // handed back through `willRestoreState`. A connected peripheral does not
        // answer a scan, so without this the receiver the app is actually talking to
        // is the one missing from the list: "only one of my two receivers is listed,
        // and cancelling connects me to the other one".
        discovered = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)

        // Report ONCE, when the window closes, with everything heard in it.
        scanWindowTimer?.invalidate()
        scanWindowTimer = Timer.scheduledTimer(withTimeInterval: Self.scanWindow,
                                               repeats: false) { [weak self] _ in
            guard let self else { return }
            self.central.stopScan()
            self.scanWindowTimer = nil
            // Android emits NoDevicesAvailable here. Without it the app sat in
            // `scanning` forever and told the user it was still looking, which is the
            // one thing it had finished doing. Nothing set this state before.
            if self.discovered.isEmpty {
                self.state = .noDevicesFound
            }
            self.onDiscover?(self.discovered)
        }
    }

    func stopScan() {
        // Our own timer dies either way: a scan window that cannot be stopped at the
        // radio is still over as far as this app is concerned.
        scanWindowTimer?.invalidate()
        scanWindowTimer = nil
        guard canCommandCentral else { return }
        central.stopScan()
    }

    /// Connect to one of the peripherals found this scan.
    func connectToDiscovered(_ id: UUID) {
        guard let p = discovered.first(where: { $0.identifier == id }) else { return }
        connect(to: p)
    }

    func connect(to p: CBPeripheral) {
        // Refused rather than attempted: a connect issued while the radio is off is
        // dropped, and the app would sit in `.connecting` for a connection nobody asked
        // for. `centralManagerDidUpdateState` scans again when power returns.
        guard canCommandCentral else { return }
        stopScan()
        // Let go of the previous one FIRST. Without this, choosing the other receiver
        // left the first still connected and merely un-referenced — it keeps its
        // session with `bluetoothd`, keeps the radio busy, and keeps itself out of the
        // next scan, so it could never be chosen again.
        if let existing = peripheral, existing.identifier != p.identifier {
            central.cancelPeripheralConnection(existing)
        }
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: nil)
    }

    func disconnect() {
        // The watchdog stops either way. If the radio is off the link is already gone —
        // there is nothing to cancel, and pretending otherwise leaves a timer probing a
        // connection that no longer exists.
        stopHealthWatchdog()
        guard canCommandCentral, let p = peripheral else { return }
        central.cancelPeripheralConnection(p)
    }

    // MARK: - Sending

    /// Write one message, split to whatever the link currently allows.
    ///
    /// **The MTU is re-queried on every write, never cached.** iOS negotiates it
    /// *asynchronously after* `didConnect` and provides no MTU-changed callback
    /// (Android has `onMtuChanged`). The probe read `withoutResponse = 20` inside
    /// `didConnect` — the 23-byte default — and then received 140-byte notifications
    /// moments later. Caching the connect-time value would fragment writes ~12×
    /// more than necessary.
    ///
    /// `.withoutResponse` is the value that reflects `MTU - 3`. `.withResponse`
    /// reports 512 because CoreBluetooth performs ATT long writes transparently;
    /// it is a long-write capacity, not the MTU.
    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        guard let p = peripheral, let ch = writeChar, state == .ready else { return false }

        let chunkSize = max(1, p.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            p.writeValue(Data(bytes[offset..<end]), for: ch, type: .withoutResponse)
            offset = end
        }
        return true
    }

    // MARK: - Health watchdog (ADR-0012)

    private func startHealthWatchdog() {
        stopHealthWatchdog()
        health.reset()
        healthTimer = Timer.scheduledTimer(withTimeInterval: ConnectionHealthMonitor.dataTimeout,
                                           repeats: true) { [weak self] _ in
            self?.healthWindowElapsed()
        }
    }

    private func stopHealthWatchdog() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func healthWindowElapsed() {
        switch health.windowElapsed() {
        case .none:
            break
        case .sendProbe:
            // A receiver-answered message specifically: anything locator-bound would
            // depend on the locator being powered and in range, which is the very
            // thing that may legitimately be absent.
            onHealthProbe?()
        case .declarePhantom:
            disconnect()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothTransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            // A restored connection's GATT session is rebuilt HERE, at the first moment
            // CoreBluetooth accepts commands.
            if needsRestoredDiscovery, let p = peripheral,
               p.state == CBPeripheralState.connected {
                needsRestoredDiscovery = false
                p.discoverServices([Self.serviceUUID])
            }
            // Scanning still runs: the choice of receiver is always offered, and a
            // restored peripheral is seeded into the list by `retrieveConnectedPeripherals`.
            startScan()
        case .poweredOff:   state = .poweredOff
        case .unauthorized: state = .unauthorized
        case .unsupported:  state = .unsupported
        default:            state = .idle
        }
    }

    /// Required when a restore identifier is set: iOS relaunches the app for a BLE
    /// event and hands back the peripherals it was managing. Without implementing
    /// this the restore key does nothing.
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = restored.first else { return }
        peripheral = p
        p.delegate = self

        // **The GATT work has to be redone, and this is the whole point of the
        // callback.** iOS restores the CONNECTION, not the session on top of it:
        // `didConnect` is not called for a peripheral that is already connected, so
        // nothing here would ever have discovered services, resolved the characteristics
        // or subscribed to notifications.
        //
        // Reported from the phone as a receiver that connected by itself with a GREY
        // icon, gated the receiver menu and refused to arm — all of which is `state`
        // stopping at `.connected` and never reaching `.ready`, because `.ready` is set
        // when the notify characteristic is subscribed. A manual rescan fixed it because
        // that path runs `didConnect` properly.
        //
        // **The discovery is issued from `centralManagerDidUpdateState`, not here.**
        // This callback runs BEFORE the central reports `.poweredOn`, and CoreBluetooth
        // drops any command issued before then — so the redo that fixes the grey icon
        // was itself liable to be discarded, restoring the exact bug it was written for.
        if p.state == CBPeripheralState.connected {
            state = .connected
            framer.reset()      // a half-frame from before the restart must not survive
            needsRestoredDiscovery = true
        } else {
            state = .connecting
        }
    }



    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Collected, not reported: the window closing is what offers the choice, so a
        // second receiver arriving late still makes the list.
        guard !discovered.contains(where: { $0.identifier == p.identifier }) else { return }
        discovered.append(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        state = .connected
        framer.reset()          // a half-frame from the previous link must not survive
        // NOTE: deliberately NOT reading maximumWriteValueLength here. See `send`.
        p.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        state = .disconnected
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        stopHealthWatchdog()
        writeChar = nil
        framer.reset()
        state = .disconnected
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothTransport: CBPeripheralDelegate {

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = p.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        p.discoverCharacteristics([Self.writeCharUUID, Self.notifyCharUUID], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case Self.writeCharUUID:
                writeChar = ch
            case Self.notifyCharUUID:
                // CoreBluetooth writes the CCCD (2902) itself — unlike Android, there
                // is no manual descriptor write to make notifications start.
                p.setNotifyValue(true, for: ch)
            default:
                break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.notifyCharUUID, ch.isNotifying, error == nil else { return }
        state = .ready
        startHealthWatchdog()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.notifyCharUUID, let data = ch.value else { return }

        // Every inbound byte counts as liveness — relayed locator traffic and probe
        // replies alike (ADR-0012). Recorded before framing, because a partial or
        // even a corrupt frame still proves the link is carrying bytes.
        health.recordDataReceived()

        let badBefore = framer.badFrameCount
        for frame in framer.append(data) {
            onFrame?(frame)
        }
        if framer.badFrameCount != badBefore {
            onBadFrameCount?(framer.badFrameCount)
            for r in framer.recentRejects.suffix(framer.badFrameCount - badBefore) { onReject?(r) }
        }
    }
}
