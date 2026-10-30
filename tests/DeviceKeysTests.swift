import Foundation

@main struct DeviceKeysTests {
    static func main() throws {
        let first = Data(repeating: 1, count: 16).base64EncodedString()
        let second = Data(repeating: 2, count: 16).base64EncodedString()
        let clipboard = """
        {"capturedAt":1,"keys":{"primaryKey":{"key":"\(first)","keyId":1},"secondaryKey":{"key":"\(second)","keyId":2}}}
        """
        func decode(_ text: String) throws -> DeviceKeys {
            let keys = try JSONDecoder().decode(DeviceKeys.self, from: Data(text.utf8))
            try keys.validate()
            return keys
        }
        let keys = try decode(clipboard)
        precondition(keys.ordered.count == 2 && keys.ordered[0].keyId == 1 && keys.ordered[1].keyId == 2)
        let invalid = [
            "not JSON",
            "{\"keys\":{}}",
            clipboard.replacingOccurrences(of: second, with: "not-base64"),
            clipboard.replacingOccurrences(of: second, with: Data([1]).base64EncodedString()),
            clipboard.replacingOccurrences(of: "\"keyId\":2", with: "\"keyId\":1"),
            clipboard.replacingOccurrences(of: "\"keyId\":2", with: "\"keyId\":4294967296"),
        ]
        for text in invalid {
            do {
                _ = try decode(text)
                fatalError("Accepted invalid device keys")
            } catch {}
        }
        print("PASS: pasted key JSON, missing keys, Base64, key length, duplicate IDs and UInt32 bounds")
    }
}
