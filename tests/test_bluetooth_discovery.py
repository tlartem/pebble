import pathlib
import subprocess
import tempfile
import unittest


class BluetoothDiscoveryTests(unittest.TestCase):
    def test_discovery_and_scoped_database_confirmation(self):
        source = (pathlib.Path(__file__).resolve().parents[1] / 'App/BandConnection.swift').read_text()
        start = source.index('    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor')
        end = source.index('\n    func peripheral(', start + 1)
        callback = source[start:end]
        start = source.index('    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices')
        end = source.index('\n    func peripheral(', start + 1)
        services_callback = source[start:end]
        start = source.index('    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor')
        end = source.index('        if active, band === peripheral, characteristic.uuid == linkStatusID', start)
        value_callback = source[start:end] + '    }\n'
        # Exercise the actual delegate callback with real GATT attributes and a stand-in radio.
        harness = '''
import Foundation
import CoreBluetooth
func characteristic(_ uuid: String, _ properties: CBCharacteristicProperties) -> CBCharacteristic {
    CBMutableCharacteristic(type: CBUUID(string: uuid), properties: properties,
                            value: nil, permissions: [.readable, .writeable])
}
func service(_ characteristics: [CBCharacteristic], uuid: String = "FD62") -> CBService {
    let service = CBMutableService(type: CBUUID(string: uuid), primary: true)
    service.characteristics = characteristics
    return service
}
final class CBPeripheral {
    var services: [CBService]?
    var discoveries: [([CBUUID]?, CBService)] = []
    var subscriptions: [CBCharacteristic] = []
    var reads: [CBCharacteristic] = []
    var writes: [(Data, CBCharacteristic, CBCharacteristicWriteType)] = []
    func discoverCharacteristics(_ ids: [CBUUID]?, for service: CBService) {
        discoveries.append((ids, service))
    }
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        subscriptions.append(characteristic)
    }
    func readValue(for characteristic: CBCharacteristic) { reads.append(characteristic) }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append((data, characteristic, type))
    }
}
final class Probe {
    let active = true
    let band: CBPeripheral
    let txID = CBUUID(string: "FF01"), rxID = CBUUID(string: "FF02")
    let linkStatusService = CBUUID(string: "FD00"), linkStatusID = CBUUID(string: "FD02")
    let confirmationServiceID = CBUUID(string: "AC2F0045-8182-4BE5-91E0-2992E6B40EBB")
    let confirmationPointerID = CBUUID(string: "AC2F0145-8182-4BE5-91E0-2992E6B40EBB")
    var confirmationWrite: CBCharacteristic?
    var tx: CBCharacteristic?, rx: CBCharacteristic?
    var hasStarted = false
    init(_ peripheral: CBPeripheral) { band = peripheral }
    func finish(_ title: String, _ detail: String) { fatalError(title) }
    func record(_ event: String, value: String = "") {}
''' + services_callback + '\n' + callback + '\n' + value_callback + '''
}
let peripheral = CBPeripheral(), firstTX = characteristic("FF01", [.writeWithoutResponse])
let firstRX = characteristic("FF02", [.notify])
let probe = Probe(peripheral)
probe.peripheral(peripheral, didDiscoverCharacteristicsFor: service([firstTX, firstRX]), error: nil)
probe.peripheral(peripheral, didDiscoverCharacteristicsFor: service([
    characteristic("FF01", [.writeWithoutResponse]), characteristic("FF02", [.notify])
]), error: nil)
let linkStatus = characteristic("FD02", [.read])
probe.peripheral(peripheral, didDiscoverCharacteristicsFor: service([linkStatus], uuid: "FD00"), error: nil)
precondition(peripheral.subscriptions.count == 1)
precondition(probe.tx === firstTX && probe.rx === firstRX,
             "Late service callback replaced the subscribed Bluetooth channel")
precondition(peripheral.reads.count == 1 && peripheral.reads.first === linkStatus)
print("PASS: late service callback preserves subscribed Bluetooth channel")

let pointer = characteristic("AC2F0145-8182-4BE5-91E0-2992E6B40EBB", [.read])
let acknowledgement = characteristic("3A4B9A47-2585-11EB-ADC1-0242AC120002", [.write])
let readOnlyTarget = characteristic("BEEF", [.read])
let confirmation = service([pointer, acknowledgement, readOnlyTarget], uuid: "AC2F0045-8182-4BE5-91E0-2992E6B40EBB")
peripheral.services = [confirmation]
probe.peripheral(peripheral, didDiscoverServices: nil)
precondition(peripheral.discoveries.count == 1 && peripheral.discoveries[0].0 == nil &&
             peripheral.discoveries[0].1 === confirmation)
probe.peripheral(peripheral, didDiscoverCharacteristicsFor: confirmation, error: nil)
precondition(peripheral.reads.last === pointer, "Missing GATT database confirmation read")
(pointer as! CBMutableCharacteristic).value = acknowledgement.uuid.data
probe.peripheral(peripheral, didUpdateValueFor: pointer, error: nil)
precondition(peripheral.writes.count == 1 && peripheral.writes[0].0 == Data([0]) &&
             peripheral.writes[0].1 === acknowledgement && peripheral.writes[0].2 == .withResponse,
             "Missing GATT database acknowledgement")
probe.peripheral(peripheral, didUpdateValueFor: pointer, error: nil)
precondition(peripheral.writes.count == 1, "Duplicate callback repeated the acknowledgement")
for invalid in [Data(), Data([1, 2, 3]), Data([1, 2, 3, 4]), Data(repeating: 0, count: 17),
                pointer.uuid.data, CBUUID(string: "FEED").data, readOnlyTarget.uuid.data] {
    probe.confirmationWrite = nil
    (pointer as! CBMutableCharacteristic).value = invalid
    probe.peripheral(peripheral, didUpdateValueFor: pointer, error: nil)
}
precondition(peripheral.writes.count == 1, "Malformed or unknown pointer caused a write")
let otherService = service([pointer, acknowledgement], uuid: "FD62")
(pointer as! CBMutableCharacteristic).value = acknowledgement.uuid.data
probe.peripheral(peripheral, didUpdateValueFor: pointer, error: nil)
precondition(otherService.uuid != probe.confirmationServiceID && peripheral.writes.count == 1,
             "Confirmation escaped its designated GATT service")
precondition(peripheral.subscriptions.count == 1 && probe.rx === firstRX)
print("PASS: scoped GATT acknowledgement and invalid pointer rejection")
'''
        with tempfile.TemporaryDirectory(prefix='pebble-bluetooth-test-') as directory:
            swift = pathlib.Path(directory) / 'probe.swift'
            binary = pathlib.Path(directory) / 'probe'
            swift.write_text(harness)
            compiled = subprocess.run(['swiftc', str(swift), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
