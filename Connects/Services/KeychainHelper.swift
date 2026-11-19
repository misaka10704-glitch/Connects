import Foundation
import Security

enum KeychainHelper {
    private static let services = [
        "com.misamisa.connects",
        "com.connects.app" // migrate from older builds
    ]

    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let service = services[0]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        // Also clear legacy service to avoid stale keys
        for s in services.dropFirst() {
            var legacy = query
            legacy[kSecAttrService as String] = s
            SecItemDelete(legacy as CFDictionary)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> String? {
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess,
               let data = result as? Data,
               let string = String(data: data, encoding: .utf8),
               !string.isEmpty {
                // Migrate to primary service if found in legacy
                if service != services[0] {
                    _ = save(key: key, value: string)
                }
                return string
            }
        }
        return nil
    }

    static func delete(key: String) {
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    enum Keys {
        static let deepseekAPIKey = "deepseek_api_key"
        static let kimiAPIKey = "kimi_api_key"
        static let dashscopeAPIKey = "dashscope_api_key"
        static let zhipuAPIKey = "zhipu_api_key"
        static let doubaoAPIKey = "doubao_api_key"

        static let all: [String] = [
            deepseekAPIKey,
            kimiAPIKey,
            dashscopeAPIKey,
            zhipuAPIKey,
            doubaoAPIKey,
        ]

        /// Keychain account for a BYOK profile's API key.
        static func customAPIKey(_ providerID: String) -> String {
            "custom_key_\(providerID)"
        }
    }

    static func exportSnapshot(extraKeys: [String] = []) -> [String: String] {
        var snapshot: [String: String] = [:]
        for key in Keys.all + extraKeys {
            if let value = load(key: key) {
                snapshot[key] = value
            }
        }
        return snapshot
    }

    static func importSnapshot(_ snapshot: [String: String]) {
        for (key, value) in snapshot {
            _ = save(key: key, value: value)
        }
    }
}
