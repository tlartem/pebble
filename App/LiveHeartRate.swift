import Foundation
import CoreBluetooth
import Combine

/// Reads the standard Bluetooth Heart Rate Profile while "Share heart rate" is
/// on in Google Health. Read-only: it subscribes to measurements and never
/// writes to the band's own transport, so Google Health keeps working.
final class LiveHeartRate: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum State: Equatable { case off, searching, streaming, unavailable(String) }
    @Published private(set) var state = State.off
    @Published private(set) var bpm: Int?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var rr: [Double] = []
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var watchdog: Timer?
    private let service = CBUUID(string: "180D")
    private let measurement = CBUUID(string: "2A37")

    func start() {
        guard state == .off || { if case .unavailable = state { return true }; return false }() else { return }
        state = .searching; bpm = nil; rr = []
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) } else { centralManagerDidUpdateState(central!) }
        arm(20, L("No live heart rate. Turn on Share heart rate for your Air in Google Health, then try again."))
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; state = .off
    }

    private func arm(_ seconds: TimeInterval, _ message: String) {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.central?.stopScan()
            if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
            self.peripheral = nil; self.state = .unavailable(message)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard state == .searching else { return }
        guard central.state == .poweredOn else {
            if central.state == .unauthorized || central.state == .poweredOff { stop(); state = .unavailable(L("Bluetooth is unavailable.")) }
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [service])
        if let air = connected.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("air") }) ?? connected.first { connect(air) }
        else { central.scanForPeripherals(withServices: [service]) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.localizedCaseInsensitiveContains("air") else { return }
        connect(peripheral)
    }
    private func connect(_ target: CBPeripheral) {
        guard peripheral == nil else { return }
        central?.stopScan(); peripheral = target; target.delegate = self
        central?.connect(target)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        peripheral.discoverServices([service])
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral, state != .off else { return }
        self.peripheral = nil; state = .unavailable(L("Live heart rate stopped. Sharing may have ended."))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let hrs = peripheral.services?.first(where: { $0.uuid == service }) else { return }
        peripheral.discoverCharacteristics([measurement], for: hrs)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == measurement }) else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, let sample = Self.parse(data) else { return }
        if sample.bpm > 0 { bpm = sample.bpm; updatedAt = Date() }
        rr = Array((rr + sample.rr).suffix(300))
        state = .streaming
        arm(15, L("Live heart rate paused. Check that sharing is still on."))
    }

    /// Heart Rate Measurement (0x2A37): flags, 8/16-bit value, optional energy
    /// expended, optional RR intervals in 1/1024 s.
    static func parse(_ data: Data) -> (bpm: Int, rr: [Double])? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        var index = 1
        let bpm: Int
        if flags & 0x01 != 0 {
            guard bytes.count >= 3 else { return nil }
            bpm = Int(bytes[1]) | Int(bytes[2]) << 8; index = 3
        } else {
            guard bytes.count >= 2 else { return nil }
            bpm = Int(bytes[1]); index = 2
        }
        guard bpm < 260 else { return nil }
        if flags & 0x08 != 0 { index += 2 }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while index + 1 < bytes.count {
                let raw = Int(bytes[index]) | Int(bytes[index + 1]) << 8
                rr.append(Double(raw) / 1024 * 1000); index += 2
            }
        }
        return (bpm, rr)
    }
}
