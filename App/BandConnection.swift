import Foundation
import CoreBluetooth
import Combine
import UIKit

final class BandConnection: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Ready when you are"
    @Published var detail = "Read the alarms already saved on your Air."
    @Published var active = false
    @Published var alarms: AlarmList?
    @Published var keysReady = false
    @Published var capabilities: BandCapabilities?
    @Published var activity: ActivityReading?
    @Published var deviceInfo: BandDeviceInfo?
    @Published private(set) var activityUpdateID = 0
    @Published var lastRead: Date?
    @Published var haptic: HapticSetting?
    @Published var notificationAccess = false
    @Published private(set) var systemSharingReady = false
    @Published private(set) var preview = false
    @Published private(set) var observedEvents: [ObservedEvent] = []
    struct ObservedEvent: Identifiable { let id = UUID(); let date: Date; let name: String }
    private var finishWaiters: [(Bool) -> Void] = []
    private static let successTitles: Set<String> = ["Up to date", "Alarms refreshed", "Vibration complete", "Alarms saved", "Vibration setting saved", "Observation ended"]
    var busy: Bool { active || closing != nil }
    @Published private(set) var lastSucceeded: Bool?
    private var realSnapshot: Snapshot?
    private struct Snapshot: Codable { let alarms: AlarmList?; let activity: ActivityReading?; let lastRead: Date?; var deviceInfo: BandDeviceInfo? = nil }
    private struct Journal: Codable { let date: Date; let before: AlarmList; let change: AlarmChange }
    private enum Purpose { case refresh, activity, observe, systemSharing, primePulse, change(AlarmChange), haptic(HapticSetting, UInt64), pulse(BuzzPattern) }
    private var pendingSharingProbe = false
    private var authenticatedPeripheralID: UUID?
    private var observedEventCount = 0
    private enum Phase { case alarms, capabilities, deviceInfo, activity, writing, verifying, creationFinalizing, haptic, hapticWriting, hapticVerifying, pulseOn, pulseOff, pulseFinalVerify, pulseProbe, pulseRestoring, pulseVerified }
    private var correctedCreation = false
    private var pendingPulse: HapticPulseTransaction?
    private var pulseTimer: Timer?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var completedPulseGroups = 0
    private var pulseSucceeded = false
    private var pulseCompletion: ((Bool) -> Void)?
    private var primeCompletion: ((Bool) -> Void)?
    private var pulseReady = false
    var observingEvents: Bool { if case .observe = purpose { return true }; return false }
    var canStart: Bool { !active && closing == nil && !preview && keysReady }
    var canPulse: Bool { canStart && [2, 3].contains(haptic?.intensity ?? 0) && capabilities?.hapticIntensities.isSuperset(of: [2, 3]) == true }
    private var purpose = Purpose.refresh
    private var phase = Phase.alarms
    private var beforeWrite: AlarmList?
    private var writeSent = false
    private var writeVerified = false
    private var central: CBCentralManager!
    private var band: CBPeripheral?
    private var closing: CBPeripheral?
    private var progressTimer: Timer?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var transport: OpaquePointer?
    private var pump: Timer?
    private var timeout: Timer?
    private var didRead = false
    private var session = UUID()
    private var hasStarted = false
    private var sent = 0
    private var received = 0
    private var lastDTLSState: Int32?
    private var events: [[String: String]] = []
    private var captureEnabled = false
    private var fragments: [[String: String]] = []
    private var outgoing: [Data] = []
    func enableDiagnosticCapture() { captureEnabled = true }
    /// USB-launched acceptance operations use the same conflict checks as the
    /// UI. Edits/deletions require an explicit ID and the cached prior state.
    func runDiagnostic(_ operation: String, alarmID: UInt64?) {
        enableDiagnosticCapture()
        switch operation {
        case "refresh": start()
        case "events": begin(.observe)
        case "ancs": pendingSharingProbe = true; begin(.refresh)
        case "vibration":
            let groups = alarmID.flatMap { (1...4).contains($0) ? Int($0) : nil } ?? 1
            testVibration(groups: groups)
        case "activity": begin(.activity)
        case "create-disabled-alarm": create(AlarmDraft(hour: 12, minute: 34, enabled: false, smartWake: false, days: 0))
        case "edit-test-alarm", "delete-test-alarm":
            guard let alarmID, let original = alarms?.alarms.first(where: { $0.id == alarmID }) else {
                status = "Test alarm not found"; return
            }
            if operation == "edit-test-alarm" {
                save(original, hour: 12, minute: 35, enabled: false, smartWake: false, days: 96)
            } else { delete(original) }
        default: status = "Unknown diagnostic operation"
        }
    }
    private func capture(_ direction: String, _ data: Data) {
        guard captureEnabled, fragments.count < 512 else { return }
        fragments.append(["direction": direction, "data": data.base64EncodedString(), "time": ISO8601DateFormatter().string(from: Date())])
    }
    private let service = CBUUID(string: "FD62")
    private let legacy = CBUUID(string: "ABBAFF00-E56A-484C-B832-8B17CF6CBFE8")
    private let txID = CBUUID(string: "ABBAFF01-E56A-484C-B832-8B17CF6CBFE8")
    private let rxID = CBUUID(string: "ABBAFF02-E56A-484C-B832-8B17CF6CBFE8")
    override init() {
        super.init(); refreshKeys()
        if let data = try? Data(contentsOf: document("band-snapshot.json")),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            alarms = saved.alarms; activity = saved.activity; lastRead = saved.lastRead; deviceInfo = saved.deviceInfo
            status = "Saved on this iPhone"; detail = "Refresh to read the current band state."
        }
    }
    func setPreview(_ enabled: Bool) {
        guard !active, preview != enabled else { return }
        if enabled {
            realSnapshot = Snapshot(alarms: alarms, activity: activity, lastRead: lastRead, deviceInfo: deviceInfo)
            preview = true
            let draft = AlarmDraft(hour: 7, minute: 30, enabled: true, smartWake: true, days: 31)
            let config = try! draft.configuration()
            let weekend = try! AlarmDraft(hour: 9, minute: 0, enabled: false, smartWake: false, days: 96).configuration()
            alarms = try? AlarmList(data: Proto.message(1, Proto.integer(1, 8) + Proto.integer(2, 1)) + Proto.message(2, Proto.integer(1, 1) + Proto.message(2, config)) + Proto.message(2, Proto.integer(1, 2) + Proto.message(2, weekend)))
            activity = try? ActivityReading(data: Proto.integer(2, 8246) + Proto.integer(7, 68) + Proto.integer(8, 3))
            deviceInfo = try? BandDeviceInfo(data: Proto.integer(13, 76))
            lastRead = Date(); status = "Preview mode"; detail = "Example data. Bluetooth is never opened."
        } else {
            preview = false; alarms = realSnapshot?.alarms; activity = realSnapshot?.activity; lastRead = realSnapshot?.lastRead; deviceInfo = realSnapshot?.deviceInfo
            realSnapshot = nil; status = "Ready when you are"; detail = "Refresh when your Air is available."
        }
    }
    private func cache() {
        guard !preview else { return }
        do { try JSONEncoder().encode(Snapshot(alarms: alarms, activity: activity, lastRead: lastRead, deviceInfo: deviceInfo)).write(to: document("band-snapshot.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { record("cache_failed") }
    }
    func refreshKeys() { keysReady = (try? DeviceKeys.load()) != nil }
    func start() { begin(.refresh) }
    func save(_ original: BandAlarm, hour: Int, minute: Int, enabled: Bool, smartWake: Bool, days: UInt8? = nil) {
        guard let configuration = try? original.edited(hour: hour, minute: minute, enabled: enabled, smartWake: smartWake, days: days) else { return }
        begin(.change(.edit(original, configuration)))
    }
    func create(_ draft: AlarmDraft) {
        guard let configuration = try? draft.configuration() else { return }
        begin(.change(.create(configuration)))
    }
    func setIntensity(_ intensity: UInt64) {
        guard let haptic, capabilities?.hapticIntensities.contains(intensity) == true else { return }
        begin(.haptic(haptic, intensity))
    }
    func delete(_ alarm: BandAlarm) { begin(.change(.delete(alarm))) }
    func testVibration(groups: Int = 1, completion: ((Bool) -> Void)? = nil) {
        let patterns: [Int: BuzzPattern] = [1: .single, 2: .double, 3: .triple, 4: .urgent]
        guard let pattern = patterns[groups] else { completion?(false); return }
        vibrate(pattern, completion: completion)
    }
    func vibrate(_ pattern: BuzzPattern, completion: ((Bool) -> Void)? = nil) {
        if pulseReady, active, transport != nil {
            pulseReady = false; purpose = .pulse(pattern); pulseCompletion = completion
            read(3, phase: .haptic, title: "Checking vibration setting")
            return
        }
        guard canStart else { completion?(false); return }
        pulseCompletion = completion
        begin(.pulse(pattern))
        if !active { let callback = pulseCompletion; pulseCompletion = nil; callback?(false) }
    }
    /// Reads only the current activity snapshot: the shortest band session.
    func readActivity() { begin(.activity) }
    func observeEvents() { begin(.observe) }
    /// Suspends until the current session ends; true when it succeeded.
    func run(_ start: () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            var resumed = false
            finishWaiters.append { ok in if !resumed { resumed = true; continuation.resume(returning: ok) } }
            start()
            if !active, let index = finishWaiters.indices.last { let waiter = finishWaiters.remove(at: index); waiter(false) }
        }
    }
    func vibrate(_ pattern: BuzzPattern) async -> Bool {
        await withCheckedContinuation { continuation in vibrate(pattern) { continuation.resume(returning: $0) } }
    }
    /// Waits for a previous session to close (bounded) before starting another.
    func waitUntilIdle(seconds: Double = 20) async -> Bool {
        var waited = 0.0
        while !canStart && waited < seconds { try? await Task.sleep(nanoseconds: 200_000_000); waited += 0.2 }
        return canStart
    }
    func prepareVibration(completion: @escaping (Bool) -> Void) {
        guard canStart else { completion(false); return }
        primeCompletion = completion
        begin(.primePulse)
        if !active { let callback = primeCompletion; primeCompletion = nil; callback?(false) }
    }
    private func simulate(_ requested: Purpose) {
        if case let .change(change) = requested, let before = alarms {
            guard change.validate(before: before) else { status = "Alarm changed or list full"; return }
            var entries = before.alarms
            switch change {
            case .edit(let original, let config):
                entries.removeAll { $0.id == original.id }; entries.append(decodeExample(id: original.id, config: config))
            case .create(let config): entries.append(decodeExample(id: (entries.map(\.id).max() ?? 0) + 1, config: config))
            case .delete(let original): entries.removeAll { $0.id == original.id }
            }
            alarms = AlarmList(maximum: before.maximum, smartWakeSupported: before.smartWakeSupported, alarms: entries.sorted { $0.id < $1.id })
            status = "Preview updated"
        } else { status = "Preview refreshed" }
        lastRead = Date(); detail = "Example data only. Nothing was sent to a band."
    }
    private func decodeExample(id: UInt64, config: Data) -> BandAlarm {
        try! AlarmList(data: Proto.message(1, Proto.integer(1, 8) + Proto.integer(2, 1)) + Proto.message(2, Proto.integer(1, id) + Proto.message(2, config))).alarms[0]
    }
    private func begin(_ requested: Purpose) {
        guard !active else { return }
        if preview { simulate(requested); return }
        guard closing == nil else { status = "Finishing disconnection"; detail = "Try again in a moment."; return }
        refreshKeys()
        guard keysReady else { status = "Device key needed"; detail = "Import the protected key file from this Mac first."; return }
        let recoveryURL = document("haptic-pulse-transaction.json")
        pendingPulse = nil
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            do {
                let saved = try JSONDecoder().decode(HapticPulseTransaction.self, from: Data(contentsOf: recoveryURL))
                let expected = try HapticPulseTransaction(original: saved.original, supported: [2, 3])
                guard expected.alternate.matches(saved.alternate) else { throw Proto.Failure.invalid }
                pendingPulse = saved
            }
            catch { status = "Vibration backup unavailable"; detail = "Unlock your iPhone before retrying. The recovery backup has been preserved."; return }
        }
        session = UUID()
        completedPulseGroups = 0; pulseSucceeded = false; pulseReady = false
        purpose = requested; phase = .alarms; beforeWrite = nil; writeSent = false; writeVerified = false; correctedCreation = false
        active = true; didRead = false; hasStarted = false; sent = 0; received = 0; events = []; fragments = []; outgoing = []; observedEventCount = 0; systemSharingReady = false
        lastDTLSState = nil
        if case .observe = requested { observedEvents = [] }
        status = "Finding your Air"; detail = "Keep your band close to your iPhone."
        record("begin", value: UIApplication.shared.applicationState == .background ? "background" : "foreground")
        if let fingerprint = try? DeviceKeys.load().fingerprint() { record("key_fingerprint", value: fingerprint) }
        let observing: Bool = { if case .observe = requested { return true }; return false }()
        let sharing: Bool = { if case .systemSharing = requested { return true }; return false }()
        timeout = Timer(timeInterval: observing ? 120 : 35, repeats: false) { [weak self] _ in
            self?.finish(observing ? "Observation ended" : sharing ? "System sharing check ended" : "Connection timed out", "Connection closed. Your band keeps tracking.")
        }
        if let timeout { RunLoop.main.add(timeout, forMode: .common) }
        progressTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.record("progress") }
        if let progressTimer { RunLoop.main.add(progressTimer, forMode: .common) }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { centralManagerDidUpdateState(central) }
    }
    func stop() {
        guard active else { return }
        // Finish restoring a temporary setting within the bounded session, even
        // if the app backgrounds. Expiration retains the recovery journal.
        if pendingPulse != nil { status = "Restoring vibration setting"; return }
        finish("Disconnected", "Connection closed.")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard active else { return }
        guard central.state == .poweredOn else {
            if central.state == .unauthorized { finish("Bluetooth access needed", "Allow Bluetooth access in iPhone Settings.") }
            else if central.state == .poweredOff { finish("Bluetooth is off", "Switch it on in iPhone Settings, then try again.") }
            return
        }
        if case .systemSharing = purpose {
            guard let authenticatedPeripheralID,
                  let verified = central.retrievePeripherals(withIdentifiers: [authenticatedPeripheralID]).first else {
                finish("Verified Air unavailable", "Refresh before checking system sharing."); return
            }
            connect(verified); return
        }
        let known = central.retrieveConnectedPeripherals(withServices: [service, legacy])
        if known.count == 1 { connect(known[0]) }
        else if known.count > 1 { finish("More than one band found", "Move other Fitbit devices away before trying again.") }
        else { central.scanForPeripherals(withServices: [service, legacy], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]) }
    }
    private func connect(_ peripheral: CBPeripheral) {
        guard active, band == nil else { return }
        central.stopScan(); band = peripheral; peripheral.delegate = self
        status = "Connecting"; record("connecting")
        if case .systemSharing = purpose {
            record("ancs_requested")
            central.connect(peripheral, options: [CBConnectPeripheralOptionRequiresANCS: true])
        } else { central.connect(peripheral, options: nil) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name,
              name.localizedCaseInsensitiveContains("air") else { return }
        connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active, band === peripheral else { central.cancelPeripheralConnection(peripheral); return }
        notificationAccess = peripheral.ancsAuthorized
        record("connected"); record("ancs_authorized", value: String(notificationAccess))
        if case .systemSharing = purpose {
            // This phase makes no GATT application writes or DTLS connection.
            // iOS and the existing paired accessory own the ANCS protocol.
            status = notificationAccess ? "System sharing authorized" : "Waiting for system sharing"
            detail = "Checking the existing paired Air. No vibration command is sent by this app."
            systemSharingReady = notificationAccess
            record("ancs_probe_no_application_writes")
            return
        }
        peripheral.discoverServices([service, legacy])
    }
    func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
        guard active, band === peripheral else { return }
        notificationAccess = peripheral.ancsAuthorized
        record("ancs_authorization_updated", value: String(notificationAccess))
        if case .systemSharing = purpose {
            systemSharingReady = notificationAccess
            status = notificationAccess ? "System sharing authorized" : "System sharing not authorized"
        }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if closing === peripheral { closing = nil; return }
        if band === peripheral { finish("Couldn’t connect", "Open Google Health to check your band, then try again.") }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if closing === peripheral { closing = nil; return }
        if active, band === peripheral { finish("Connection ended", "Your band is disconnected from this app.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard active, band === peripheral else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else { finish("Band service unavailable", "No settings were changed."); return }
        for service in services { peripheral.discoverCharacteristics([txID, rxID], for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active, band === peripheral else { return }
        guard error == nil else { finish("Band service unavailable", "No settings were changed."); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == txID { tx = characteristic }
            if characteristic.uuid == rxID { rx = characteristic }
        }
        guard !hasStarted, let tx, let rx else { return }
        guard tx.properties.contains(.writeWithoutResponse), rx.properties.contains(.notify) else { finish("Unsupported band transport", "No settings were changed."); return }
        hasStarted = true
        peripheral.setNotifyValue(true, for: rx)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active, band === peripheral, characteristic === rx, transport == nil else { return }
        guard error == nil, characteristic.isNotifying else { finish("Couldn’t receive from band", "No settings were changed."); return }
        do {
            let keys = try DeviceKeys.load().ordered
            let ids = keys.map(\.keyId), bytes = keys.flatMap { [UInt8](Data(base64Encoded: $0.key)!) }
            let mtu = UInt16(min(512, peripheral.maximumWriteValueLength(for: .withoutResponse)))
            transport = ids.withUnsafeBufferPointer { ids in bytes.withUnsafeBufferPointer { bytes in
                air_transport_create(mtu, ids.baseAddress, bytes.baseAddress, { context, bytes, count in
                    guard let context, let bytes else { return -1 }
                    let owner = Unmanaged<BandConnection>.fromOpaque(context).takeUnretainedValue()
                    guard owner.band != nil, owner.tx != nil, owner.active else { return -1 }
                    // Gattlink can emit a later sequence while retrying a sink
                    // that returned WOULD_BLOCK. Accept into a bounded FIFO so
                    // CoreBluetooth backpressure cannot reorder those packets.
                    guard owner.outgoing.count < 64 else { return 1 }
                    owner.outgoing.append(Data(bytes: bytes, count: count))
                    owner.flushOutgoing()
                    return 0
                }, { context, code, bytes, count in
                    guard let context else { return }
                    let owner = Unmanaged<BandConnection>.fromOpaque(context).takeUnretainedValue()
                    let body = bytes.map { Data(bytes: $0, count: count) } ?? Data()
                    let session = owner.session
                    DispatchQueue.main.async {
                        guard owner.session == session else { return }
                        owner.handleResponse(code: code, body: body)
                    }
                }, Unmanaged.passUnretained(self).toOpaque())
            } }
            guard let transport else { finish("Couldn’t start secure connection", "No settings were changed."); return }
            if case .observe = purpose {
                let result = air_transport_observe_events(transport, { context, bytes, count in
                    guard let context, let bytes else { return }
                    let owner = Unmanaged<BandConnection>.fromOpaque(context).takeUnretainedValue()
                    let body = Data(bytes: bytes, count: count), session = owner.session
                    DispatchQueue.main.async {
                        guard owner.active, owner.session == session, owner.observedEventCount < 128,
                              let names = try? BandEvent.diagnosticNames(data: body) else { return }
                        for name in names where owner.observedEventCount < 128 {
                            owner.observedEventCount += 1
                            owner.record("band_event", value: name)
                            owner.observedEvents.insert(ObservedEvent(date: Date(), name: name), at: 0)
                        }
                    }
                })
                guard result == 0 else { finish("Observer unavailable", "No settings were changed."); return }
            }
            status = "Securing the connection"; record("handshake")
            guard air_transport_start(transport) == 0 else { finish("Couldn’t start secure connection", "No settings were changed."); return }
            work()
        } catch { finish("Device key unavailable", "Unlock your iPhone and try again.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active, band === peripheral, characteristic === rx, let transport, let data = characteristic.value else { return }
        guard error == nil else { finish("Receive failed", "No settings were changed."); return }
        capture("receive", data)
        received += 1
        let result = data.withUnsafeBytes { air_transport_receive(transport, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        guard result == 0 else { record("receive_error", value: String(result)); finish("Band transport stopped", "No settings were changed."); return }
        work()
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard active, band === peripheral, let transport else { return }
        flushOutgoing()
        air_transport_writable(transport); work()
    }
    private func flushOutgoing() {
        guard active, let band, let tx else { return }
        while band.canSendWriteWithoutResponse, !outgoing.isEmpty {
            let data = outgoing.removeFirst()
            capture("send", data); sent += 1
            band.writeValue(data, for: tx, type: .withoutResponse)
        }
    }
    private func work() {
        guard active, let transport else { return }
        pump?.invalidate(); pump = nil
        var delay = UInt32.max
        guard air_transport_work(transport, &delay) == 0 else { finish("Band transport stopped", "No settings were changed."); return }
        let state = air_transport_state(transport)
        if state != lastDTLSState { lastDTLSState = state; record("dtls_state", value: String(state)) }
        if state == 2 && !didRead {
            authenticatedPeripheralID = band?.identifier
            didRead = true; status = "Reading alarms"; record("authenticated")
            var resource: UInt32 = 0
            if pendingPulse != nil { phase = .pulseProbe; status = "Checking vibration recovery"; beginPulseWindow(); resource = 3 }
            else {
                switch purpose {
                case .pulse, .primePulse: phase = .capabilities; status = "Checking vibration support"; resource = 1
                case .activity: phase = .activity; status = "Reading activity"; resource = 2
                default: break
                }
            }
            let result = air_transport_read(transport, resource)
            guard result == 0 else { record("read_error", value: String(result)); finish("Couldn’t read alarms", "No settings were changed."); return }
            // A new request schedules a timer after the previous work() result.
            delay = 0
        } else if state == 3 || state < 0 { finish("Secure connection failed", "No settings were changed."); return }
        if delay != UInt32.max {
            pump = Timer(timeInterval: max(0.001, Double(delay) / 1000), repeats: false) { [weak self] _ in self?.work() }
            if let pump { RunLoop.main.add(pump, forMode: .common) }
        }
    }
    private func handleResponse(code: Int32, body: Data) {
        guard active else { return }
        switch phase {
        case .alarms:
            guard code == 69, let result = try? AlarmList(data: body) else { record("alarm_response_rejected", value: String(code)); finish("Couldn’t read alarms", "Try refreshing again with Google Health closed."); return }
            alarms = result; lastRead = Date(); record("alarms_read", value: String(result.alarms.count))
            cache()
            if case let .change(change) = purpose {
                guard change.validate(before: result) else {
                    finish("Alarm changed or list full", "The latest list is loaded. Review it before saving."); return
                }
                guard let transport else { return }
                do {
                    try JSONEncoder().encode(Journal(date: Date(), before: result, change: change)).write(to: document("alarm-transaction.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch { finish("Couldn’t preserve original alarms", "Nothing was changed. Check available iPhone storage."); return }
                beforeWrite = result; phase = .writing; status = "Saving alarms"
                let outcome: Int32
                switch change {
                case .edit(let original, let config):
                    outcome = config.withUnsafeBytes { air_transport_update_alarm(transport, UInt32(original.id), $0.bindMemory(to: UInt8.self).baseAddress, config.count) }
                case .create(let config):
                    outcome = config.withUnsafeBytes { air_transport_create_alarm(transport, $0.bindMemory(to: UInt8.self).baseAddress, config.count) }
                case .delete(let original): outcome = air_transport_delete_alarm(transport, UInt32(original.id))
                }
                guard outcome == 0 else { finish("Couldn’t send change", "Nothing was changed."); return }
                writeSent = true; record("alarm_change_sent"); work()
            } else { read(1, phase: .capabilities, title: "Checking band features") }
        case .capabilities:
            capabilities = code == 69 ? try? BandCapabilities(data: body) : nil
            if capabilities?.settings.contains(1) != true { haptic = nil }
            record("capabilities_response", value: String(code))
            if capabilities?.settings.contains(1) == true {
                read(3, phase: .haptic, title: "Reading vibration setting")
            } else if case .haptic = purpose {
                finish("Vibration control unavailable", "Your band did not advertise this setting. Nothing was changed.")
            } else if case .pulse = purpose {
                finish("Vibration control unavailable", "Your band did not advertise the required setting.")
            } else if case .primePulse = purpose {
                finish("Vibration control unavailable", "Your band did not advertise the required setting.")
            } else { read(4, phase: .deviceInfo, title: "Reading battery") }
        case .haptic:
            haptic = code == 69 ? try? HapticSetting(data: body) : nil
            if case .primePulse = purpose {
                guard let haptic, let capabilities,
                      (try? HapticPulseTransaction(original: haptic, supported: capabilities.hapticIntensities)) != nil else {
                    finish("Vibration test unavailable", "The test needs supported Low and High settings, with vibration already on."); return
                }
                pulseReady = true; status = "Ready for test notification"; record("notification_ready")
                let callback = primeCompletion; primeCompletion = nil; callback?(true)
            } else if case .pulse = purpose {
                guard let haptic, let capabilities,
                      let transaction = try? HapticPulseTransaction(original: haptic, supported: capabilities.hapticIntensities) else {
                    finish("Vibration test unavailable", "The test needs supported Low and High settings, with vibration already on."); return
                }
                do { try JSONEncoder().encode(transaction).write(to: document("haptic-pulse-transaction.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                catch { finish("Couldn’t preserve vibration setting", "Nothing was changed."); return }
                pendingPulse = transaction
                beginPulseWindow()
                completedPulseGroups = 0
                emitPulseOn()
            } else if case let .haptic(original, value) = purpose {
                guard let fresh = haptic, fresh.configuration == original.configuration,
                      capabilities?.hapticIntensities.contains(value) == true,
                      let configuration = try? fresh.response(changingTo: value), let transport else {
                    finish("Vibration setting changed or unavailable", "Refresh and review the current setting before saving."); return
                }
                do { try JSONEncoder().encode(fresh).write(to: document("haptic-before-edit.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                catch { finish("Couldn’t preserve original setting", "Nothing was changed."); return }
                phase = .hapticWriting; status = "Saving vibration setting"
                let outcome = configuration.withUnsafeBytes { air_transport_set_haptics(transport, $0.bindMemory(to: UInt8.self).baseAddress, configuration.count) }
                guard outcome == 0 else { finish("Couldn’t send setting", "Nothing was changed."); return }
                writeSent = true; record("haptic_change_sent"); work()
            } else { read(4, phase: .deviceInfo, title: "Reading battery") }
        case .deviceInfo:
            if code == 69, let info = try? BandDeviceInfo(data: body) { deviceInfo = info; cache() }
            record("device_info_response", value: String(code))
            read(2, phase: .activity, title: "Reading activity")
        case .hapticWriting:
            record("haptic_change_response", value: String(code))
            read(3, phase: .hapticVerifying, title: "Checking vibration setting")
        case .hapticVerifying:
            guard code == 69, let fresh = try? HapticSetting(data: body), case let .haptic(original, value) = purpose,
                  let expectedData = try? original.response(changingTo: value), let expected = try? HapticSetting(data: expectedData),
                  let actualFields = try? Proto(fresh.configuration).fields, let expectedFields = try? Proto(expected.configuration).fields,
                  actualFields == expectedFields else {
                finish("Save needs checking", "Refresh to check the band’s current setting."); return
            }
            haptic = fresh; writeVerified = true; record("haptic_change_verified")
            finish("Vibration setting saved", "Read back from your band. This changes intensity, not event patterns.")
        case .activity:
            let reading = code == 69 ? try? ActivityReading(data: body) : nil
            if let reading { activity = reading; cache(); activityUpdateID += 1 }
            record("activity_response", value: String(code))
            if case .observe = purpose {
                status = "Observing band interactions"; detail = "Read-only event observation ends automatically after two minutes."
                record("observer_ready"); return
            }
            finish(reading == nil ? "Alarms refreshed" : "Up to date", reading == nil ? "Activity wasn’t available. Any previous reading retains its timestamp." : "Connection closed. Your band keeps tracking.")
        case .pulseOn:
            // One pulse = switch to the alternate intensity (buzz), hold briefly,
            // then switch straight back (buzz). No read between: a read per toggle
            // is what made every pattern take so long they felt identical.
            record("pulse_on", value: String(code))
            guard case .pulse(let pattern) = purpose, let pendingPulse else { finish("Vibration recovery needed", "Refresh to inspect the saved setting."); return }
            pulseTimer = Timer(timeInterval: pattern.holdSeconds, repeats: false) { [weak self] _ in
                self?.sendPulseSetting(pendingPulse.original, phase: .pulseOff)
            }
            if let pulseTimer { RunLoop.main.add(pulseTimer, forMode: .common) }
        case .pulseOff:
            record("pulse_off", value: String(code))
            guard case .pulse(let pattern) = purpose else { finish("Vibration recovery needed", "Refresh to inspect the saved setting."); return }
            completedPulseGroups += 1
            if completedPulseGroups < pattern.pulses {
                pulseTimer = Timer(timeInterval: pattern.gap, repeats: false) { [weak self] _ in self?.emitPulseOn() }
                if let pulseTimer { RunLoop.main.add(pulseTimer, forMode: .common) }
            } else {
                // Confirm the band is back on the original intensity exactly once.
                read(3, phase: .pulseFinalVerify, title: "Checking vibration setting")
            }
        case .pulseFinalVerify:
            guard code == 69, let current = try? HapticSetting(data: body), pendingPulse?.recovery(for: current) == .alreadyRestored else {
                finish("Vibration recovery needed", "Refresh to inspect the saved setting."); return
            }
            pulseSucceeded = true
            completePulse(current)
        case .pulseProbe:
            guard code == 69, let current = try? HapticSetting(data: body), let pendingPulse else {
                finish("Vibration recovery needed", "Refresh to inspect the saved setting."); return
            }
            switch pendingPulse.recovery(for: current) {
            case .alreadyRestored: completePulse(current)
            case .restore: sendPulseSetting(pendingPulse.original, phase: .pulseRestoring)
            case .conflict: finish("Vibration setting changed", "The current value differs from both saved states. The app has preserved the backup and will not overwrite another change.")
            }
        case .pulseRestoring:
            record("pulse_restore_response", value: String(code))
            read(3, phase: .pulseVerified, title: "Verifying original setting")
        case .pulseVerified:
            guard code == 69, let current = try? HapticSetting(data: body),
                  pendingPulse?.recovery(for: current) == .alreadyRestored else {
                finish("Vibration recovery needed", "Refresh to inspect the saved setting."); return
            }
            completePulse(current)
        case .writing:
            record("alarm_edit_response", value: String(code))
            // Even a missing acknowledgement can follow an applied PUT. Read the
            // actual state; never blindly retry a mutation or claim it failed.
            read(0, phase: .verifying, title: "Checking saved alarm")
        case .creationFinalizing:
            record("alarm_activation_response", value: String(code))
            read(0, phase: .verifying, title: "Verifying disabled alarm")
        case .verifying:
            guard code == 69, let result = try? AlarmList(data: body),
                  case let .change(change) = purpose, let beforeWrite else {
                finish("Save needs checking", "Refresh your alarms to see the band’s current state."); return
            }
            alarms = result; lastRead = Date(); cache()
            if !correctedCreation, let (id, configuration) = change.activationCorrection(before: beforeWrite, after: result), let transport {
                correctedCreation = true; phase = .creationFinalizing
                status = "Finishing disabled alarm"
                let outcome = configuration.withUnsafeBytes { air_transport_update_alarm(transport, UInt32(id), $0.bindMemory(to: UInt8.self).baseAddress, configuration.count) }
                guard outcome == 0 else { finish("Save needs checking", "Check the new alarm’s enabled state."); return }
                record("alarm_activation_correction_sent"); work(); return
            }
            guard change.verified(before: beforeWrite, after: result) else {
                finish("Save needs checking", "The band returned a different alarm list. Review it before making another change."); return
            }
            writeVerified = true; record("alarm_edit_verified")
            finish("Alarms saved", "Read back from your band. Unrelated alarms are unchanged.")
        }
    }
    private func beginPulseWindow() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        timeout?.invalidate()
        timeout = Timer(timeInterval: 25, repeats: false) { [weak self] _ in
            self?.finish("Vibration recovery needed", "Refresh to inspect the saved setting.")
        }
        if let timeout { RunLoop.main.add(timeout, forMode: .common) }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Restore Air vibration") { [weak self] in
            self?.finish("Vibration recovery needed", "Refresh to check and restore the saved setting.")
        }
    }
    /// Begins one pulse of the active pattern by switching to the alternate intensity.
    private func emitPulseOn() {
        guard let pendingPulse else { finish("Vibration recovery needed", "Refresh to inspect the saved setting."); return }
        sendPulseSetting(pendingPulse.alternate, phase: .pulseOn)
    }
    private func sendPulseSetting(_ value: HapticSetting, phase: Phase) {
        guard let transport, let payload = try? value.response(changingTo: value.intensity) else {
            finish("Vibration recovery needed", "The original setting is backed up on this iPhone."); return
        }
        self.phase = phase
        status = phase == .pulseOn || phase == .pulseOff ? "Buzzing your band" : "Restoring vibration setting"
        let result = payload.withUnsafeBytes { air_transport_set_haptics(transport, $0.bindMemory(to: UInt8.self).baseAddress, payload.count) }
        guard result == 0 else { finish("Vibration recovery needed", "Refresh to inspect the saved setting."); return }
        record(phase == .pulseOn ? "pulse_on_sent" : phase == .pulseOff ? "pulse_off_sent" : "pulse_restore_sent")
        work()
    }
    private func completePulse(_ value: HapticSetting) {
        do { try FileManager.default.removeItem(at: document("haptic-pulse-transaction.json")) }
        catch { finish("Recovery backup retained", "The original setting was verified, but the recovery file could not be cleared."); return }
        pendingPulse = nil; haptic = value
        record("pulse_original_verified")
        finish(pulseSucceeded ? "Vibration complete" : "Vibration setting restored", "Original intensity restored and read back from your Air.")
    }
    private func read(_ resource: UInt32, phase: Phase, title: String) {
        guard active, let transport else { return }
        self.phase = phase; status = title
        guard air_transport_read(transport, resource) == 0 else { finish("Connection ended", "Refresh to see the latest band state."); return }
        work()
    }
    private func document(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }
    private func finish(_ title: String, _ subtitle: String) {
        systemSharingReady = false
        pulseReady = false
        active = false; progressTimer?.invalidate(); progressTimer = nil; pump?.invalidate(); pump = nil; timeout?.invalidate(); timeout = nil
        pulseTimer?.invalidate(); pulseTimer = nil
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        central?.stopScan()
        if let transport { air_transport_destroy(transport); self.transport = nil }
        if let band, band.state != .disconnected { closing = band; central?.cancelPeripheralConnection(band) }
        band = nil; tx = nil; rx = nil; outgoing = []
        status = writeSent && !writeVerified ? "Save needs checking" : title
        detail = writeSent && !writeVerified ? "The request may have reached your band. Refresh before retrying; your prior settings are backed up on this iPhone." : subtitle
        if pendingPulse != nil {
            status = "Vibration recovery needed"
            detail = "The original setting is backed up. Refresh checks it before any further changes; a conflicting setting is never overwritten."
        }
        if captureEnabled, let data = try? JSONSerialization.data(withJSONObject: fragments) {
            try? data.write(to: document("transport-diagnostic.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        record("ended", value: status)
        let callback = pulseCompletion; pulseCompletion = nil
        callback?(pulseSucceeded)
        let succeeded = Self.successTitles.contains(status) || (pulseSucceeded && status == "Vibration complete")
        lastSucceeded = succeeded
        let waiters = finishWaiters; finishWaiters = []
        waiters.forEach { $0(succeeded) }
        let readyCallback = primeCompletion; primeCompletion = nil
        readyCallback?(false)
        if pendingSharingProbe {
            pendingSharingProbe = false
            guard authenticatedPeripheralID != nil, title == "Up to date" || title == "Alarms refreshed" else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for _ in 0..<20 where !self.canStart { try? await Task.sleep(nanoseconds: 100_000_000) }
                guard self.canStart, UIApplication.shared.applicationState != .background else { return }
                self.begin(.systemSharing)
            }
        }
    }
    private func record(_ event: String, value: String = "") {
        events.append(["event": event, "value": value, "time": ISO8601DateFormatter().string(from: Date())])
        let report: [String: Any] = ["events": events, "sentFragments": sent, "receivedFragments": received]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("connection-report.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
