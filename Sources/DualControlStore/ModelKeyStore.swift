#if canImport(Darwin)
    import DualControlCore
    import Foundation
    import Security

    /// The owner's Anthropic API key for the model relay (D11), in the owner's login keychain: this device only,
    /// readable while the Mac is unlocked. The owner enters it in the window; it never passes through the agent, the
    /// shim or a chat. `claude-agent` is another user and has no access to the owner's keychain.
    public enum ModelKeyStore {
        static let service = "Dual Control model relay"
        static let account = "anthropic-api-key"

        /// The saved key, if any.
        public static func load() -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
                let key = String(data: data, encoding: .utf8), ModelRelayPolicy.keyProblem(key) == nil
            else { return nil }
            return key
        }

        /// Saves `key`, replacing an earlier one. Why not, or `nil`.
        public static func save(_ key: String) -> String? {
            if let problem = ModelRelayPolicy.keyProblem(key) { return problem }
            delete()
            let item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecValueData as String: Data(key.utf8),
            ]
            let status = SecItemAdd(item as CFDictionary, nil)
            return status == errSecSuccess ? nil : "the keychain refused it (status \(status))"
        }

        /// Removes the saved key, if any.
        public static func delete() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
#endif
