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

/// Parses and validates an encrypted VLESS (Reality or TLS, TCP) URI used as a chained relay hop.
struct VlessRelayURI: Equatable {
    let uuid: String
    let server: String
    let port: Int
    let security: String       // "reality" or "tls"
    let sni: String
    let flow: String
    let fingerprint: String
    let publicKey: String
    let shortID: String

    init(_ rawText: String, localPort: Int = 17898) throws {
        let value = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "vless",
              let rawUUID = components.user, !rawUUID.isEmpty, UUID(uuidString: rawUUID) != nil,
              components.password == nil,
              let rawHost = components.host, !rawHost.isEmpty,
              let resolvedPort = components.port, (1...65535).contains(resolvedPort) else {
            throw UserFacingError("加密中转链接格式无效，请填写完整的 vless://UUID@服务器:端口?...（TLS 或 Reality）。")
        }

        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        let validDNS = host.range(of: #"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#,
                                  options: .regularExpression) != nil
        guard validDNS || SettingsValidator.isIPAddress(host), !host.contains("..") else {
            throw UserFacingError("加密中转服务器地址无效。")
        }
        guard !(["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) && resolvedPort == localPort) else {
            throw UserFacingError("加密中转不能指向本工具自己的本机端口。")
        }

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            params[item.name.lowercased()] = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let transport = (params["type"] ?? "tcp").lowercased()
        guard transport.isEmpty || transport == "tcp" else {
            throw UserFacingError("加密中转链接当前仅支持 TCP 传输（type=tcp）。")
        }
        let encryption = (params["encryption"] ?? "none").lowercased()
        guard encryption.isEmpty || encryption == "none" else {
            throw UserFacingError("VLESS 中转链接的 encryption 参数须为 none。")
        }
        let resolvedSecurity = (params["security"] ?? "").lowercased()
        guard resolvedSecurity == "reality" || resolvedSecurity == "tls" else {
            throw UserFacingError("加密中转链接必须启用 Reality 或 TLS（security=reality 或 security=tls）。")
        }

        let resolvedSNI = params["sni"] ?? ""
        if !resolvedSNI.isEmpty {
            let validSNI = resolvedSNI.range(of: #"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#,
                                             options: .regularExpression) != nil
            guard validSNI && !resolvedSNI.contains("..") else {
                throw UserFacingError("加密中转链接的 SNI（sni）不是有效域名。")
            }
        }
        let resolvedFlow = params["flow"] ?? ""
        if !resolvedFlow.isEmpty {
            guard resolvedFlow.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else {
                throw UserFacingError("加密中转链接的 flow 参数格式无效。")
            }
        }
        let resolvedFP = params["fp"] ?? (resolvedSecurity == "reality" ? "chrome" : "")
        if !resolvedFP.isEmpty {
            guard resolvedFP.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw UserFacingError("加密中转链接的指纹参数（fp）格式无效。")
            }
        }
        let resolvedPBK = params["pbk"] ?? ""
        let resolvedSID = params["sid"] ?? ""
        if resolvedSecurity == "reality" {
            guard !resolvedSNI.isEmpty else {
                throw UserFacingError("VLESS Reality 中转链接缺少伪装域名（sni）。")
            }
            guard (32...64).contains(resolvedPBK.count),
                  resolvedPBK.range(of: #"^[A-Za-z0-9_+/-]+=*$"#, options: .regularExpression) != nil else {
                throw UserFacingError("VLESS Reality 中转链接缺少有效的公钥（pbk）。")
            }
            if !resolvedSID.isEmpty {
                guard resolvedSID.count <= 16,
                      resolvedSID.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil else {
                    throw UserFacingError("VLESS Reality 中转链接的 short-id（sid）须为不超过 16 位的十六进制字符。")
                }
            }
        }

        self.uuid = rawUUID
        self.server = host
        self.port = resolvedPort
        self.security = resolvedSecurity
        self.sni = resolvedSNI
        self.flow = resolvedFlow
        self.fingerprint = resolvedFP
        self.publicKey = resolvedPBK
        self.shortID = resolvedSID
    }

    func toMihomoProxy(name: String = "RELAY") -> [String: Any] {
        var proxy: [String: Any] = [
            "name": name,
            "type": "vless",
            "server": server,
            "port": port,
            "uuid": uuid,
            "network": "tcp",
            "tls": true,
            "udp": false
        ]
        if !flow.isEmpty { proxy["flow"] = flow }
        if !sni.isEmpty { proxy["servername"] = sni }
        if !fingerprint.isEmpty { proxy["client-fingerprint"] = fingerprint }
        if security == "reality" {
            var realityOpts: [String: Any] = ["public-key": publicKey]
            if !shortID.isEmpty { realityOpts["short-id"] = shortID }
            proxy["reality-opts"] = realityOpts
        }
        return proxy
    }
}
