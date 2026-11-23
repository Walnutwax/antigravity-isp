import Foundation

struct ProxyImport {
    let server: String
    let port: Int
    let proxyType: String
    let username: String
    let password: String

    init(_ text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = value.contains("://") ? value : "http://" + value
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "socks5", "socks5h"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil else {
            throw UserFacingError("请复制 HTTP、HTTPS 或 SOCKS5 代理链接，或服务器:端口；不支持订阅链接、路径和查询参数。")
        }
        proxyType = scheme == "socks5h" ? "socks5" : scheme
        server = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        port = components.port ?? (proxyType == "https" ? 443 : proxyType == "socks5" ? 1080 : 80)
        username = try Self.decode(components.percentEncodedUser)
        password = try Self.decode(components.percentEncodedPassword)
        guard !username.isEmpty || password.isEmpty else {
            throw UserFacingError("代理链接包含密码时，也需要填写用户名。")
        }
        var settings = ProxySettings()
        settings.server = server
        settings.port = port
        settings.proxyType = proxyType
        settings.username = username
        try SettingsValidator.validate(settings)
    }

    private static func decode(_ value: String?) throws -> String {
        guard let value else { return "" }
        guard let decoded = value.removingPercentEncoding else {
            throw UserFacingError("代理链接中的账号或密码编码无效，请重新复制或手动填写。")
        }
        return decoded
    }
}
