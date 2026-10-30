import Foundation
import Security
import CryptoKit

struct DeviceKeys: Codable {
    struct Key: Codable { let key: String; let keyId: UInt32 }
    let keys: [String: Key]
    var ordered: [Key] { [keys["primaryKey"], keys["secondaryKey"]].compactMap { $0 } }
    func validate() throws {
        guard ordered.count == 2, ordered[0].keyId != ordered[1].keyId,
              ordered.allSatisfy({ Data(base64Encoded: $0.key)?.count == 16 }) else { throw Failure.invalid }
    }
    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(self)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    enum Failure: Error { case invalid, keychain }
    static let service = "com.medpar.air.companion.device-keys"
    static func load() throws -> DeviceKeys {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("device-keys.json")
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: "air"]
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            let data = try Data(contentsOf: url)
            let keys = try JSONDecoder().decode(DeviceKeys.self, from: data); try keys.validate()
            let normalized = try JSONEncoder().encode(keys)
            let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: normalized] as CFDictionary)
            if update == errSecItemNotFound {
                var add = base; add[kSecValueData as String] = normalized
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw Failure.keychain }
            } else if update != errSecSuccess { throw Failure.keychain }
            try FileManager.default.removeItem(at: url)
            return keys
        }
        var query = base; query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw Failure.keychain }
        let keys = try JSONDecoder().decode(DeviceKeys.self, from: data); try keys.validate()
        migrateAccessibility(base)
        return keys
    }
    /// Background alerts (calls, step checks, Shortcuts) can run while the
    /// iPhone is locked. Keys stay device-only and become readable after the
    /// first unlock following a restart, instead of only while unlocked.
    private static func migrateAccessibility(_ base: [String: Any]) {
        let flag = "deviceKeysAfterFirstUnlock"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let status = SecItemUpdate(base as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        if status == errSecSuccess { UserDefaults.standard.set(true, forKey: flag) }
    }
}
