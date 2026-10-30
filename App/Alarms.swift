import Foundation

struct BandAlarm: Identifiable, Codable {
    let id: UInt64
    let enabled: Bool
    let hour: Int
    let minute: Int
    let smartWake: Bool
    let days: UInt8
    let configuration: Data
    let recurring: Bool
    var time: String { String(format: "%02d:%02d", hour, minute) }
    var schedule: String {
        guard recurring else { return L("Once") }
        if days == 127 { return L("Every day") }
        if days == 31 { return L("Weekdays") }
        if days == 96 { return L("Weekends") }
        let names = [L("Mon"), L("Tue"), L("Wed"), L("Thu"), L("Fri"), L("Sat"), L("Sun")]
        return names.enumerated().filter { days & (1 << $0.offset) != 0 }.map(\.element).joined(separator: ", ")
    }
    func edited(hour: Int, minute: Int, enabled: Bool, smartWake: Bool, days: UInt8? = nil) throws -> Data {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { throw Proto.Failure.invalid }
        let existing = try Proto(configuration)
        let time = try Proto(existing.oneBytes(5, required: true))
        let changedTime = time.replacing(1, with: Proto.integer(1, UInt64(hour)))
        let changedMinute = try Proto(changedTime).replacing(2, with: Proto.integer(2, UInt64(minute)))
        var result = existing.replacing(5, with: Proto.message(5, changedMinute))
        result = try Proto(result).replacing(1, with: Proto.integer(1, enabled ? 1 : 0))
        result = try Proto(result).replacing(3, with: Proto.integer(3, smartWake ? 1 : 0))
        if let days {
            guard days < 128 else { throw Proto.Failure.invalid }
            result = try Proto(result).replacing(4, with: Proto.integer(4, days == 0 ? 0 : 1))
            result = try Proto(result).replacing(6, with: Proto.message(6, Data([days])))
        }
        return result
    }
}
struct AlarmList: Codable {
    init(maximum: Int, smartWakeSupported: Bool, alarms: [BandAlarm]) {
        self.maximum = maximum; self.smartWakeSupported = smartWakeSupported; self.alarms = alarms
    }
    let maximum: Int
    let smartWakeSupported: Bool
    let alarms: [BandAlarm]
    init(data: Data) throws {
        let root = try Proto(data)
        let capabilities = try Proto(root.oneBytes(1, required: true))
        let maximumValue = try capabilities.oneInt(1)
        guard (1...32).contains(maximumValue) else { throw Proto.Failure.invalid }
        maximum = Int(maximumValue)
        smartWakeSupported = try capabilities.oneBool(2)
        alarms = try root.bytes(2).map { body in
            let entry = try Proto(body)
            let configuration = try entry.oneBytes(2, required: true)
            let config = try Proto(configuration)
            let time = try Proto(config.oneBytes(5, required: true))
            let hour = try time.oneInt(1), minute = try time.oneInt(2), second = try time.oneInt(3)
            let days = try config.oneBytes(6)
            guard hour < 24, minute < 60, second < 60, days.count <= 1,
                  try entry.oneInt(1) <= UInt32.max else { throw Proto.Failure.invalid }
            _ = try config.oneBool(2)
            return BandAlarm(id: try entry.oneInt(1), enabled: try config.oneBool(1),
                             hour: Int(hour), minute: Int(minute), smartWake: try config.oneBool(3),
                             days: days.first ?? 0, configuration: configuration, recurring: try config.oneBool(4))
        }
        guard alarms.count <= maximum, Set(alarms.map(\.id)).count == alarms.count else { throw Proto.Failure.invalid }
    }
}
struct Proto {
    enum Failure: Error { case invalid }
    enum Value: Equatable { case integer(UInt64), bytes(Data), fixed(Data) }
    var fields: [Int: [Value]] = [:]
    private var encodedFields: [(Int, Data)] = []
    init(_ data: Data) throws {
        guard data.count <= 4096 else { throw Failure.invalid }
        let source = [UInt8](data); var position = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard position < source.count else { throw Failure.invalid }
                let byte = source[position]; position += 1
                guard index < 9 || byte <= 1 else { throw Failure.invalid }
                value |= UInt64(byte & 127) << (index * 7)
                if byte < 128 { return value }
            }
            throw Failure.invalid
        }
        while position < source.count {
            let start = position
            let tag = try varint(), number = Int(tag >> 3), wire = tag & 7
            guard number > 0, number < (1 << 29) else { throw Failure.invalid }
            if wire == 0 { fields[number, default: []].append(.integer(try varint())) }
            else {
                let size: Int
                if wire == 2 { let raw = try varint(); guard raw <= 4096 else { throw Failure.invalid }; size = Int(raw) }
                else if wire == 1 { size = 8 }
                else if wire == 5 { size = 4 }
                else { throw Failure.invalid }
                guard size <= source.count - position else { throw Failure.invalid }
                let value = Data(source[position..<position + size])
                fields[number, default: []].append(wire == 2 ? .bytes(value) : .fixed(value))
                position += size
            }
            encodedFields.append((number, Data(source[start..<position])))
        }
    }
    func oneInt(_ field: Int) throws -> UInt64 {
        guard let values = fields[field] else { return 0 }
        guard values.count == 1, case .integer(let value) = values[0] else { throw Failure.invalid }
        return value
    }
    func oneBool(_ field: Int) throws -> Bool {
        let value = try oneInt(field)
        guard value <= 1 else { throw Failure.invalid }
        return value == 1
    }
    func bytes(_ field: Int) throws -> [Data] {
        try (fields[field] ?? []).map { guard case .bytes(let bytes) = $0 else { throw Failure.invalid }; return bytes }
    }
    func oneBytes(_ field: Int, required: Bool = false) throws -> Data {
        let values = try bytes(field)
        guard values.count <= 1, !required || values.count == 1 else { throw Failure.invalid }
        return values.first ?? Data()
    }
    func replacing(_ field: Int, with replacement: Data) -> Data {
        var output = Data(), inserted = false
        for (number, data) in encodedFields {
            if number == field {
                if !inserted { output += replacement; inserted = true }
            } else { output += data }
        }
        if !inserted { output += replacement }
        return output
    }
    static func varint(_ input: UInt64) -> Data {
        var value = input, result = Data()
        repeat { var byte = UInt8(value & 127); value >>= 7; if value > 0 { byte |= 128 }; result.append(byte) } while value > 0
        return result
    }
    static func integer(_ field: UInt64, _ value: UInt64) -> Data { varint(field << 3) + varint(value) }
    static func message(_ field: UInt64, _ data: Data) -> Data { varint((field << 3) | 2) + varint(UInt64(data.count)) + data }
    func integers(_ field: Int) throws -> [UInt64] {
        var result: [UInt64] = []
        for value in fields[field] ?? [] {
            switch value {
            case .integer(let number): result.append(number)
            case .bytes(let packed):
                var number: UInt64 = 0, shift = 0
                for byte in packed {
                    guard shift < 64, shift < 63 || byte <= 1 else { throw Failure.invalid }
                    number |= UInt64(byte & 127) << shift
                    if byte < 128 { result.append(number); number = 0; shift = 0 }
                    else { shift += 7 }
                }
                guard shift == 0 else { throw Failure.invalid }
            case .fixed: throw Failure.invalid
            }
        }
        return result
    }
}

/// A new alarm uses the documented configuration fields. Existing alarms retain
/// all unrecognized fields, including the separate repeating/snooze flag.
struct AlarmDraft {
    var hour = 7
    var minute = 0
    var enabled = true
    var smartWake = false
    var days: UInt8 = 0
    func configuration() throws -> Data {
        guard (0..<24).contains(hour), (0..<60).contains(minute), days < 128 else { throw Proto.Failure.invalid }
        return Proto.integer(1, enabled ? 1 : 0) + Proto.integer(2, 0)
            + Proto.integer(3, smartWake ? 1 : 0) + Proto.integer(4, days == 0 ? 0 : 1)
            + Proto.message(5, Proto.integer(1, UInt64(hour)) + Proto.integer(2, UInt64(minute)) + Proto.integer(3, 0))
            + Proto.message(6, Data([days]))
    }
}

enum AlarmChange: Codable {
    case edit(BandAlarm, Data)
    case create(Data)
    case delete(BandAlarm)
    func validate(before: AlarmList) -> Bool {
        switch self {
        case .create: return before.alarms.count < before.maximum
        case .edit(let original, _), .delete(let original):
            return before.alarms.contains { $0.id == original.id && $0.configuration == original.configuration }
        }
    }
    func verified(before: AlarmList, after: AlarmList) -> Bool {
        guard before.maximum == after.maximum else { return false }
        func same(_ a: Data, _ b: Data) -> Bool {
            guard let lhs = try? Proto(a).fields, let rhs = try? Proto(b).fields else { return false }
            return lhs == rhs
        }
        let affected: UInt64?
        switch self { case .edit(let a, _), .delete(let a): affected = a.id; case .create: affected = nil }
        guard before.alarms.filter({ $0.id != affected }).allSatisfy({ prior in
            after.alarms.contains { $0.id == prior.id && same($0.configuration, prior.configuration) }
        }) else { return false }
        switch self {
        case .edit(let original, let config):
            return before.alarms.count == after.alarms.count && after.alarms.contains { $0.id == original.id && same($0.configuration, config) }
        case .delete(let original):
            return after.alarms.count == before.alarms.count - 1 && !after.alarms.contains { $0.id == original.id }
        case .create(let config):
            let added = after.alarms.filter { candidate in !before.alarms.contains { $0.id == candidate.id } }
            return after.alarms.count == before.alarms.count + 1 && added.count == 1 && same(added[0].configuration, config)
        }
    }
    /// This Air activates a newly created alarm even when POST requests false,
    /// and may return 5.00 despite creating it. Correct only that observed field
    /// after identifying exactly one new alarm; never repeat the POST.
    func activationCorrection(before: AlarmList, after: AlarmList) -> (UInt64, Data)? {
        guard case .create(let wanted) = self,
              let desired = try? Proto(wanted), (try? desired.oneBool(1)) == false,
              before.maximum == after.maximum, after.alarms.count == before.alarms.count + 1 else { return nil }
        let added = after.alarms.filter { a in !before.alarms.contains { $0.id == a.id } }
        guard added.count == 1, let alarm = added.first, alarm.enabled,
              let corrected = try? Proto(alarm.configuration).replacing(1, with: Proto.integer(1, 0)),
              let fields = try? Proto(corrected).fields, fields == desired.fields else { return nil }
        let adjusted = AlarmList(maximum: after.maximum, smartWakeSupported: after.smartWakeSupported,
            alarms: after.alarms.map { $0.id == alarm.id ? BandAlarm(id: alarm.id, enabled: false, hour: alarm.hour, minute: alarm.minute, smartWake: alarm.smartWake, days: alarm.days, configuration: corrected, recurring: alarm.recurring) : $0 })
        guard verified(before: before, after: adjusted) else { return nil }
        return (alarm.id, corrected)
    }
}
