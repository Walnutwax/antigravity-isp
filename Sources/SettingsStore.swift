import Foundation
import Security

enum SettingsStore {
    static let keychainService = "io.github.antigravity-isp.proxy"
    static let keychainAccount = "default"

    static func load() throws -> ProxySettings {
        guard FileManager.default.fileExists(atPath: AppPaths.settingsFile.path) else { return ProxySettings() }
        do { return try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: AppPaths.settingsFile)) }
        catch { throw UserFacingError("无法读取已保存的配置，请检查专用目录中的 settings.json。") }
    }

    static func save(_ settings: ProxySettings, password: String) throws {
        try SettingsValidator.validate(settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try AppPaths.createPrivateDirectory(AppPaths.supportDirectory)
        try savePassword(password)
        try AppPaths.writePrivate(data, to: AppPaths.settingsFile)
    }

    static func loadPassword() throws -> String {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw UserFacingError("无法读取代理密码。请解锁登录钥匙串，或重新填写密码。")
        }
        return value
    }

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func savePassword(_ password: String) throws {
        let query = keychainQuery()
        if password.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw UserFacingError("无法更新钥匙串中的代理密码。")
            }
            return
        }
        let data = Data(password.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Antigravity ISP 上游代理"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw UserFacingError("无法保存代理密码，请确认登录钥匙串已解锁。")
        }
    }
}
