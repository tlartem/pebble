import pathlib
import subprocess
import tempfile
import unittest


class BluetoothDiscoveryTests(unittest.TestCase):
    def test_late_service_callback_preserves_subscribed_characteristics(self):
        source = (pathlib.Path(__file__).resolve().parents[1] / 'App/BandConnection.swift').read_text()
        start = source.index('    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor')
        end = source.index('\n    func peripheral(', start + 1)
        callback = source[start:end]
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
    var subscriptions: [CBCharacteristic] = []
    var reads: [CBCharacteristic] = []
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        subscriptions.append(characteristic)
    }
    func readValue(for characteristic: CBCharacteristic) { reads.append(characteristic) }
}
final class Probe {
    let active = true
    let band: CBPeripheral
    let txID = CBUUID(string: "FF01"), rxID = CBUUID(string: "FF02")
    let linkStatusService = CBUUID(string: "FD00"), linkStatusID = CBUUID(string: "FD02")
    var tx: CBCharacteristic?, rx: CBCharacteristic?
    var hasStarted = false
    init(_ peripheral: CBPeripheral) { band = peripheral }
    func finish(_ title: String, _ detail: String) { fatalError(title) }
    func record(_ event: String, value: String = "") {}
''' + callback + '''
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
'''
        with tempfile.TemporaryDirectory(prefix='pebble-bluetooth-test-') as directory:
            swift = pathlib.Path(directory) / 'probe.swift'
            binary = pathlib.Path(directory) / 'probe'
            swift.write_text(harness)
            subprocess.run(['swiftc', str(swift), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
