import Foundation
import Security

enum SettingsStore {
    static let keychainService = "io.github.antigravity-isp.proxy"
    static let keychainAccount = "default"
    static let subscriptionAccount = "subscription"

    static func load() throws -> ProxySettings {
        guard FileManager.default.fileExists(atPath: AppPaths.settingsFile.path) else { return ProxySettings() }
        do { return try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: AppPaths.settingsFile)) }
        catch { throw UserFacingError("无法读取已保存的配置，请检查专用目录中的 settings.json。") }
    }

    static func save(_ settings: ProxySettings, password: String, subscriptionURL: String? = nil) throws {
        try SettingsValidator.validate(settings)
        if settings.useSubscription {
            try SettingsValidator.validateSubscriptionURL(try subscriptionURL ?? loadSubscriptionURL())
        }
        let data = try encode(settings)
        try AppPaths.createPrivateDirectory(AppPaths.supportDirectory)
        try savePassword(password)
        if let subscriptionURL {
            try saveSecret(subscriptionURL, account: subscriptionAccount, label: "Antigravity ISP 订阅地址")
        }
        try AppPaths.writePrivate(data, to: AppPaths.settingsFile)
    }

    static func saveRouting(_ routing: RoutingPolicy) throws {
        var settings = try load()
        settings.directDomains = routing.directDomains
        settings.directDomainSuffixes = routing.directDomainSuffixes
        try AppPaths.writePrivate(try encode(settings), to: AppPaths.settingsFile)
    }

    private static func encode(_ settings: ProxySettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    /// The node catalog is not secret, but it is still written as a private file.
    static func loadSubscriptionCatalog() -> SubscriptionCatalog? {
        guard let data = try? Data(contentsOf: AppPaths.subscriptionCatalogFile) else { return nil }
        return try? JSONDecoder().decode(SubscriptionCatalog.self, from: data)
    }

    static func saveSubscriptionCatalog(_ catalog: SubscriptionCatalog) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AppPaths.writePrivate(try encoder.encode(catalog), to: AppPaths.subscriptionCatalogFile)
    }

    static func loadPassword() throws -> String {
        try loadSecret(account: keychainAccount)
    }

    static func loadSubscriptionURL() throws -> String {
        try loadSecret(account: subscriptionAccount)
    }

    private static func loadSecret(account: String) throws -> String {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw UserFacingError("无法读取代理密码或订阅地址。请解锁登录钥匙串，或重新填写。")
        }
        return value
    }

    private static func keychainQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: account]
    }

    private static func savePassword(_ password: String) throws {
        try saveSecret(password, account: keychainAccount, label: "Antigravity ISP 上游代理")
    }

    private static func saveSecret(_ value: String, account: String, label: String) throws {
        let query = keychainQuery(account: account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw UserFacingError("无法更新钥匙串中的代理密码或订阅地址。")
            }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw UserFacingError("无法保存代理密码或订阅地址，请确认登录钥匙串已解锁。")
        }
    }
}
