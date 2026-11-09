import Foundation
import Security

/// Passwords and tokens live only in the login Keychain (service com.lockedin.courier, account = Courier account id).
public enum Keychain {
    static let service = "com.lockedin.courier"

    public static func set(_ secret: String, for account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrLabel as String] = "Courier – \(account)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw MailError.server("Keychain: \(status)") }
    }

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
