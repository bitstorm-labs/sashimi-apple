import Foundation
import Security
import os

enum KeychainHelper {
    private static let service = "com.sashimi.jellyfin"
    private static let logger = Logger(subsystem: "com.sashimi.app", category: "Keychain")

#if targetEnvironment(simulator)
    // Simulator builds do not have a stable application access group when the
    // app is installed without signing. Keep a local-only fallback so both
    // Debug and Release simulator runs survive relaunches. Device builds never
    // compile this path and continue to use the Keychain exclusively.
    private static let simulatorFallbackPrefix = "debug.simulator.credential."
#endif

#if targetEnvironment(simulator)
    private static func saveSimulatorFallback(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: simulatorFallbackPrefix + key)
    }
#endif

    static func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        // ...ThisDeviceOnly: the access token must not travel in an encrypted
        // iCloud backup to a different device. Staying on AfterFirstUnlock
        // (rather than WhenUnlocked) is deliberate -- tvOS reads the token
        // before any user interaction on cold boot, and WhenUnlocked has no
        // meaning on a device with no passcode.
        var addAttributes = query
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addAttributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Update in place rather than delete-then-add so a failed write
            // can't destroy the existing value.
            //
            // Accessibility is restated here on purpose: an item created by an
            // older build carries the old class forever otherwise, so existing
            // installs would never pick up ThisDeviceOnly.
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if updateStatus == errSecSuccess {
#if targetEnvironment(simulator)
                saveSimulatorFallback(value, forKey: key)
#endif
                return true
            }
#if targetEnvironment(simulator)
            if updateStatus == errSecMissingEntitlement {
                saveSimulatorFallback(value, forKey: key)
                logger.debug("Keychain unavailable in simulator; saved credential in the local simulator store")
                return true
            }
#endif
            logger.error("Keychain update failed (status: \(updateStatus))")
            return false
        }
        if status == errSecSuccess {
#if targetEnvironment(simulator)
            saveSimulatorFallback(value, forKey: key)
#endif
            return true
        }
#if targetEnvironment(simulator)
        if status == errSecMissingEntitlement {
            saveSimulatorFallback(value, forKey: key)
            logger.debug("Keychain unavailable in simulator; saved credential in the local simulator store")
            return true
        }
#endif
        logger.error("Keychain save failed (status: \(status))")
        return false
    }

    static func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
#if targetEnvironment(simulator)
            let fallbackKey = simulatorFallbackPrefix + key
            let fallbackValue = UserDefaults.standard.string(forKey: fallbackKey)
            if let fallbackValue {
                return fallbackValue
            }
            if status == errSecMissingEntitlement {
                logger.debug("Keychain unavailable in simulator and no local credential was saved")
                return nil
            }
#endif
            if status != errSecItemNotFound {
                logger.error("Keychain read failed (status: \(status))")
            }
            return nil
        }

        return value
    }

    @discardableResult
    static func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        let deleted = status == errSecSuccess || status == errSecItemNotFound
#if targetEnvironment(simulator)
        UserDefaults.standard.removeObject(forKey: simulatorFallbackPrefix + key)
        if status == errSecMissingEntitlement {
            return true
        }
#endif
        if !deleted {
            logger.error("Keychain delete failed (status: \(status))")
        }
        return deleted
    }
}
