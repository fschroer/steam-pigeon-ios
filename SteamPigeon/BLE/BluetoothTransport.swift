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
    /// ADR-0012: send a `receiverInfoRequest`. Wired by the caller, because building
    /// that message is protocol work, not transport work.
    var onHealthProbe: (() -> Void)?

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

    /// Transport identity is `peripheral.identifier` — iOS never exposes a MAC, so
    /// Android's `macPrefix = "D8:67"` filter has no counterpart. This value is
    /// **per-install**: it differs on another phone and changes on reinstall, so it
    /// identifies *a receiver on this install* and nothing more. Locator identity is
    /// unaffected — that keys on the 32-bit `locator_id` from telemetry (ADR-0006)
    /// and stays platform-neutral.
    private static let lastPeripheralKey = "com.steampigeon.ios.lastPeripheral"

    var lastKnownPeripheral: UUID? {
        get { UserDefaults.standard.string(forKey: Self.lastPeripheralKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastPeripheralKey) }
    }

    // MARK: - Lifecycle

    override init() {
        super.init()
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

    /// Scan for the receiver by **service UUID**, never by name.
    ///
    /// Name filtering works in the foreground and silently fails in the background,
    /// where a service filter is mandatory. FFE0 is advertised by default
    /// (`03 03 E0FF`) and the receiver firmware issues no `AT+UIDS`/`AT+SADV`/`AT+UADV`
    /// that would change that — so this is the one correct filter.
    func startScan() {
        guard central.state == .poweredOn else { return }

        // Prefer a direct reconnect to the receiver we used last.
        if let known = lastKnownPeripheral,
           let p = central.retrievePeripherals(withIdentifiers: [known]).first {
            connect(to: p)
            return
        }

        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(to p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: nil)
    }

    func disconnect() {
        stopHealthWatchdog()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
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
        case .poweredOn:    startScan()
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
        state = p.state == CBPeripheralState.connected ? .connected : .connecting
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        connect(to: p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        state = .connected
        lastKnownPeripheral = p.identifier
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

        for frame in framer.append(data) {
            onFrame?(frame)
        }
    }
}
