import Foundation
import Security

enum Keychain {
    private static let service = "com.rsnav.metameet.gemini"
    static func read() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { let status = SecItemDelete(query as CFDictionary); if status != errSecSuccess && status != errSecItemNotFound { throw failure(status) }; return }
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if result == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
            if status != errSecSuccess { throw failure(status) }
        } else if result != errSecSuccess { throw failure(result) }
    }
    private static func failure(_ code: OSStatus) -> NSError { NSError(domain: "MetaMeet.Keychain", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "API 키를 안전하게 저장하지 못했습니다. (\(code))"]) }
}
