import Foundation

enum RelayConfiguration {
    /// Builds the proxy-core config.
    ///
    /// In subscription mode the node list is always a local file provider:
    /// the app downloads and validates the subscription itself (see `SubscriptionFetcher`),
    /// so the proxy core never has to reach the subscription URL on its own. That keeps
    /// startup deterministic on networks where the core's in-process TLS download stalls.
    static func make(settings: ProxySettings, password: String, subscriptionProviderPath: String?,
                     controllerSocket: String, controllerSecret: String) throws -> [String: Any] {
        try SettingsValidator.validate(settings)
        let routing = try RoutingPolicy(settings: settings)
        var configuration: [String: Any] = [
            "mixed-port": settings.localPort, "port": 0, "socks-port": 0, "redir-port": 0, "tproxy-port": 0,
            "allow-lan": false, "bind-address": "127.0.0.1", "ipv6": false,
            "mode": "rule", "log-level": "silent", "external-controller": "",
            "profile": ["store-selected": false, "store-fake-ip": false],
            "tun": ["enable": false], "dns": ["enable": false],
            "proxies": [], "rules": routing.rules
        ]
        if settings.useSubscription {
            guard let providerPath = subscriptionProviderPath, providerPath.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: providerPath) else {
                throw UserFacingError("订阅节点文件尚未就绪，请重新获取订阅。")
            }
            configuration["external-controller-unix"] = controllerSocket
            configuration["secret"] = controllerSecret
            let provider: [String: Any] = [
                "type": "file", "path": providerPath,
                "exclude-type": "direct|reject|reject-drop|pass|dns|rematch",
                "health-check": ["enable": true, "url": "https://www.gstatic.com/generate_204",
                                 "interval": 300, "timeout": 3000, "lazy": false]
            ]
            configuration["proxy-providers"] = ["SUBSCRIPTION": provider]
            var upstream: [String: Any] = [
                "name": "UPSTREAM",
                "type": settings.subscriptionNode.isEmpty ? "url-test" : "select",
                "proxies": [String](), "use": ["SUBSCRIPTION"],
                "url": "https://www.gstatic.com/generate_204", "interval": 300,
                "tolerance": 50, "lazy": false, "empty-fallback": "REJECT"
            ]
            if !settings.subscriptionNode.isEmpty {
                // Mihomo rebuilds selectors on reload and splits group filters at backticks.
                let name = NSRegularExpression.escapedPattern(for: settings.subscriptionNode)
                    .replacingOccurrences(of: "`", with: "\\x60")
                upstream["filter"] = "\\A\(name)\\z"
            }
            configuration["proxy-groups"] = [upstream]
        } else {
            configuration["proxies"] = [manualProxy(settings, password: password, name: "UPSTREAM")]
        }
        return configuration
    }

    /// Mihomo parses the config file as YAML. JSON is a YAML subset, but
    /// JSONSerialization escapes `/` as `\/` by default, which mihomo's YAML
    /// parser rejects (subscription provider paths and health-check URLs contain `/`).
    static func serialize(_ configuration: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: configuration,
                                   options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func manualProxy(_ settings: ProxySettings, password: String, name: String) -> [String: Any] {
        var proxy: [String: Any] = [
            "name": name, "type": settings.proxyType == "socks5" ? "socks5" : "http",
            "server": settings.server, "port": settings.port, "udp": false
        ]
        if settings.proxyType == "https" { proxy["tls"] = true }
        if !settings.username.isEmpty {
            proxy["username"] = settings.username
            proxy["password"] = password
        }
        return proxy
    }
}
