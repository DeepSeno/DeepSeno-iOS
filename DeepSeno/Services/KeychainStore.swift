import Foundation
import Security

/// 用 Keychain 存敏感的配对 token(替代明文 UserDefaults)。
/// 无 access group,使用 app 默认 keychain;AfterFirstUnlock 保证后台可读。
enum KeychainStore {
    private static let service = "com.enmooy.deepseno.lan"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func token(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    static func setToken(_ token: String?, account: String) {
        guard let token, !token.isEmpty else {
            deleteToken(account: account)
            return
        }
        let data = Data(token.utf8)
        // 先删后写,避免 duplicate item / 属性不一致
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attrs = baseQuery(account: account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func deleteToken(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    /// 一次性迁移:把旧的明文 UserDefaults token 移入 Keychain,然后清除明文。
    /// Keychain 已有 token 时不覆盖,但仍清除明文残留。
    static func migrateTokenIfNeeded(userDefaultsKey: String, account: String) {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: userDefaultsKey), !legacy.isEmpty else { return }
        if token(account: account) == nil {
            setToken(legacy, account: account)
        }
        defaults.removeObject(forKey: userDefaultsKey)
    }
}
