import Foundation
import Darwin

@main
struct ModelTests {
    static func main() async throws {
        var settings = ProxySettings()
        settings.server = "proxy.example.com"
        try SettingsValidator.validate(settings)
        settings.server = "2001:db8::1"
        settings.expectedExitIP = "2001:db8::2"
        try SettingsValidator.validate(settings)
        let invalidHosts = ["https://proxy.example.com", "user:secret@example.com", "host\nother", "", "a..b"]
        for host in invalidHosts {
            var sample = settings
            sample.server = host
            try expectFailure("invalid host accepted") { try SettingsValidator.validate(sample) }
        }
        for port in [-1, 0, 65536] {
            var sample = settings
            sample.port = port
            try expectFailure("invalid upstream port accepted") { try SettingsValidator.validate(sample) }
        }
        var sample = settings
        sample.localPort = 80
        try expectFailure("privileged local port accepted") { try SettingsValidator.validate(sample) }
        sample = settings
        sample.server = "127.0.0.1"
        sample.port = sample.localPort
        try expectFailure("self-proxy loop accepted") { try SettingsValidator.validate(sample) }
        sample = settings
        sample.expectedExitIP = "not-an-ip"
        try expectFailure("invalid expected IP accepted") { try SettingsValidator.validate(sample) }
        let data = try JSONEncoder().encode(settings)
        let fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(fields["password"] == nil, "Passwords must never be persisted in settings JSON")
        let decoded = try JSONDecoder().decode(ProxySettings.self, from: data)
        precondition(decoded == settings)
        try testSettingsMigration()
        try testRoutingPolicy()
        try testProxyImport()
        try testVlessRelayURI()
        try testSubscriptionParser()
        try testSubscriptionConfiguration()
        try testChainedConfigurations()
        try testSubscriptionUsage()
        try testSubscriptionCatalog()
        try testSubscriptionCurlRequest()
        try testSubscriptionCache()
        precondition(!CoreInstaller.verifiedArchive(Data("modified archive".utf8)))
        try await testInvalidCoreImport()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntigravityISP-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try AppPaths.writePrivate(data, to: file)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600 && directoryPermissions.intValue == 0o700)
        let updated = Data("replacement".utf8)
        try AppPaths.writePrivate(updated, to: file)
        let contents = try Data(contentsOf: file)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(contents == updated)
        precondition(entries == ["settings.json"])
        print("PASS: invalid configurations, self-proxy loop, password-free settings, legacy migration, routing guardrails/order, proxy URL import, VLESS relay parsing, chained landing/three-way routing/keep-alive, subscription parsing/config/usage/curl-config/cache, invalid offline core rejection, private atomic writes")
    }

    private static func testProxyImport() throws {
        let proxy = try ProxyImport("  socks5h://test%40user:p%3Aa%2Fss%25@[2001:db8::1]:1081/\n")
        precondition(proxy.proxyType == "socks5" && proxy.server == "2001:db8::1" && proxy.port == 1081)
        precondition(proxy.username == "test@user" && proxy.password == "p:a/ss%")
        let local = try ProxyImport("127.0.0.1:7890")
        precondition(local.proxyType == "http" && local.port == 7890 && local.username.isEmpty && local.password.isEmpty)
        for (address, expectedPort) in [("http://proxy.example.com", 80), ("https://proxy.example.com", 443), ("socks5://proxy.example.com", 1080)] {
            let imported = try ProxyImport(address)
            precondition(imported.port == expectedPort && imported.server == "proxy.example.com")
        }
        for invalid in ["", " ", "ftp://proxy.example.com:21", "https://example.com/subscribe?token=test-only",
                        "http://proxy.example.com#fragment", "http://proxy.example.com:0", "http://proxy.example.com:65536",
                        "http://proxy.example.com:abc", "http://proxy.example.com\nother", "http://:password@proxy.example.com",
                        "http://user%3Aname:password@proxy.example.com", "127.0.0.1:17898"] {
            try expectFailure("Invalid proxy import accepted: \(invalid)") { _ = try ProxyImport(invalid) }
        }
    }

    private static func testVlessRelayURI() throws {
        let validKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let realityURI = "  vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.amd.com&fp=chrome&pbk=\(validKey)&sid=abcd1234&type=tcp#Example\n"
        let reality = try VlessRelayURI(realityURI, localPort: 17898)
        precondition(reality.uuid == "11111111-2222-4333-8444-555555555555")
        precondition(reality.server == "relay.example.com" && reality.port == 443)
        precondition(reality.security == "reality" && reality.sni == "www.amd.com")
        precondition(reality.flow == "xtls-rprx-vision" && reality.fingerprint == "chrome")
        precondition(reality.publicKey == validKey && reality.shortID == "abcd1234")
        let realityProxy = reality.toMihomoProxy(name: "RELAY")
        precondition(realityProxy["name"] as? String == "RELAY" && realityProxy["type"] as? String == "vless")
        precondition(realityProxy["tls"] as? Bool == true && realityProxy["udp"] as? Bool == false)
        precondition(realityProxy["network"] as? String == "tcp" && realityProxy["servername"] as? String == "www.amd.com")
        precondition(realityProxy["flow"] as? String == "xtls-rprx-vision" && realityProxy["client-fingerprint"] as? String == "chrome")
        let realityOpts = realityProxy["reality-opts"] as? [String: Any]
        precondition(realityOpts?["public-key"] as? String == validKey && realityOpts?["short-id"] as? String == "abcd1234")

        // Reality without optional sid/fp defaults fingerprint to chrome and omits short-id.
        let minimalReality = try VlessRelayURI("vless://11111111-2222-4333-8444-555555555555@[2001:db8::1]:443?security=reality&sni=www.amd.com&pbk=\(validKey)")
        precondition(minimalReality.server == "2001:db8::1" && minimalReality.fingerprint == "chrome" && minimalReality.shortID.isEmpty)
        let minimalOpts = minimalReality.toMihomoProxy()["reality-opts"] as? [String: Any]
        precondition(minimalOpts?["public-key"] as? String == validKey && minimalOpts?["short-id"] == nil)

        // Plain VLESS over TLS is accepted without reality-opts.
        let tls = try VlessRelayURI("vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=tls&sni=relay.example.com&type=tcp")
        precondition(tls.security == "tls" && tls.fingerprint.isEmpty)
        let tlsProxy = tls.toMihomoProxy()
        precondition(tlsProxy["tls"] as? Bool == true && tlsProxy["reality-opts"] == nil && tlsProxy["client-fingerprint"] == nil)

        let invalidURIs = [
            "", " ",
            "vmess://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=tls",
            "vless://not-a-uuid@relay.example.com:443?security=tls",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com?security=tls",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com:0?security=tls",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=none",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=tls&type=ws",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=tls&encryption=aes",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=reality&pbk=\(validKey)",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=reality&sni=www.amd.com&pbk=short",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=reality&sni=www.amd.com&pbk=\(validKey)&sid=zzzz",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=reality&sni=www.amd.com&pbk=\(validKey)&sid=0123456789abcdef0",
            "vless://11111111-2222-4333-8444-555555555555@127.0.0.1:17898?security=tls&sni=relay.example.com",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=tls&sni=bad..example.com",
            "vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?security=tls\nextra"
        ]
        for invalid in invalidURIs {
            try expectFailure("Invalid VLESS relay URI accepted: \(invalid)") {
                _ = try VlessRelayURI(invalid, localPort: 17898)
            }
        }
    }

    private static func testInvalidCoreImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntigravityISP-core-test-" + UUID().uuidString)
        let previousHome = ProcessInfo.processInfo.environment["ANTIGRAVITY_ISP_HOME"]
        setenv("ANTIGRAVITY_ISP_HOME", directory.path, 1)
        defer {
            if let previousHome { setenv("ANTIGRAVITY_ISP_HOME", previousHome, 1) }
            else { unsetenv("ANTIGRAVITY_ISP_HOME") }
            try? FileManager.default.removeItem(at: directory)
        }
        let original = Data("existing executable must be preserved".utf8)
        try AppPaths.writePrivate(original, to: AppPaths.mihomoExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppPaths.mihomoExecutable.path)
        let archive = directory.appendingPathComponent("invalid.gz")
        try Data("not a core archive".utf8).write(to: archive)
        do {
            try await CoreInstaller.ensureInstalled(archive: archive, progress: { _ in })
            throw UserFacingError("Unverified offline core was accepted")
        } catch {
            guard error.localizedDescription.contains("校验失败") else { throw error }
        }
        let installed = try Data(contentsOf: AppPaths.mihomoExecutable)
        precondition(installed == original, "Failed imports must preserve the installed binary")
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(!entries.contains(where: { $0.hasPrefix(".core-install-") }), "Failed imports must clean staging files")
    }

    private static func testSettingsMigration() throws {
        // Literal 0.1.0 schema: this must not depend on the current encoder's fields.
        let legacy = Data(#"{"appPath":"/Applications/Antigravity.app","server":"proxy.example.com","port":8443,"proxyType":"https","username":"test-user","localPort":17899,"expectedExitIP":"203.0.113.7","autoStart":true}"#.utf8)
        var settings = try JSONDecoder().decode(ProxySettings.self, from: legacy)
        precondition(settings.directDomains.isEmpty && settings.directDomainSuffixes.isEmpty)
        precondition(!settings.themeEnabled && settings.themeNodePath.isEmpty, "Older settings must keep the theme optional")
        precondition(!settings.chainManualProxy && !settings.useRelayURI && !settings.splitChainedModelTraffic && !settings.isChained,
                     "Older settings must default chained relay options to disabled")
        precondition(settings.server == "proxy.example.com" && settings.port == 8443)
        precondition(settings.username == "test-user" && settings.localPort == 17899)
        precondition(settings.proxyType == "https" && settings.expectedExitIP == "203.0.113.7" && settings.autoStart)
        try SettingsValidator.validate(settings)

        settings.directDomains = ["docs.example.com", "downloads.example.net"]
        settings.directDomainSuffixes = ["assets.example.org"]
        settings.themeEnabled = true
        settings.themeNodePath = "/usr/local/bin/node"
        settings.useRelayURI = true
        settings.splitChainedModelTraffic = true
        let updated = try JSONEncoder().encode(settings)
        let roundTrip = try JSONDecoder().decode(ProxySettings.self, from: updated)
        precondition(roundTrip == settings, "Routing, chained relay and theme settings must survive persistence")
        let fields = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
        precondition(fields["directDomains"] as? [String] == settings.directDomains)
        precondition(fields["directDomainSuffixes"] as? [String] == settings.directDomainSuffixes)
        precondition(fields["useRelayURI"] as? Bool == true && fields["splitChainedModelTraffic"] as? Bool == true)
        precondition(fields["password"] == nil && fields["relayURI"] == nil,
                     "Migration must not introduce persisted passwords or relay URIs")
    }

    private static func testSubscriptionParser() throws {
        let yaml = """
        # comment before the document
        allow-lan: false
        proxies:
        - type: socks5
          name: HK - 香港综合
          server: example.com
        - {name: "US - 纽约, 01", type: vmess, server: example.net}
        - type: http
          name: 'TW - 台湾''s'
          ws-opts:
            path: /
        proxy-groups:
          - name: 香港
            type: select
            proxies:
              - HK - 香港综合
        rules:
          - MATCH,香港
        """
        let nodes = SubscriptionParser.nodes(in: yaml)
        precondition(nodes == [
            SubscriptionNode(name: "HK - 香港综合", type: "socks5"),
            SubscriptionNode(name: "US - 纽约, 01", type: "vmess"),
            SubscriptionNode(name: "TW - 台湾's", type: "http")
        ], "Parser must read name/type from block and flow entries only: \(nodes)")
        // A Base64-wrapped YAML subscription must normalize back to the same nodes.
        let wrapped = Data(yaml.utf8).base64EncodedString()
        precondition(SubscriptionParser.nodes(in: wrapped) == nodes, "Base64-wrapped YAML must be decoded")
        // A node list with duplicates keeps the first occurrence and order.
        let duplicates = """
        proxies:
        - name: Same
          type: ss
        - name: Same
          type: ss
        - name: Other
          type: ss
        """
        precondition(SubscriptionParser.nodes(in: duplicates).map(\.name) == ["Same", "Other"])
        // CRLF, BOM and URL-safe Base64 wrappers are all common in the wild.
        precondition(SubscriptionParser.nodes(in: yaml.replacingOccurrences(of: "\n", with: "\r\n")) == nodes,
                     "CRLF subscriptions must parse")
        precondition(SubscriptionParser.nodes(in: "\u{FEFF}" + yaml) == nodes, "A leading BOM must be ignored")
        let urlSafe = Data(yaml.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        precondition(SubscriptionParser.nodes(in: urlSafe) == nodes, "URL-safe Base64 must be decoded")
        // Comments are skipped; a quoted `#` is part of the name, a bare one is not.
        let commented = """
        proxies:
        # region comment between entries
        - name: "A #1" # real comment
          type: ss
          # nested comment
        - name: B # trailing comment
          type: vmess
        # end of proxies
        proxy-groups: []
        """
        precondition(SubscriptionParser.nodes(in: commented) == [
            SubscriptionNode(name: "A #1", type: "ss"),
            SubscriptionNode(name: "B", type: "vmess")
        ], "Comments must not corrupt names: \(SubscriptionParser.nodes(in: commented))")
        // A plain scalar may contain an apostrophe; the trailing comment is still stripped.
        let apostrophe = """
        proxies:
        - name: It's a node # comment
          type: ss
        """
        precondition(SubscriptionParser.nodes(in: apostrophe) == [SubscriptionNode(name: "It's a node", type: "ss")],
                     "Apostrophes in plain names must not swallow comments")
        // Flow-style sequences (single and multi line) list nodes too.
        let flow = "proxies: [{name: A, type: ss}, {name: \"B, C\", type: vmess}]"
        precondition(SubscriptionParser.nodes(in: flow) == [
            SubscriptionNode(name: "A", type: "ss"),
            SubscriptionNode(name: "B, C", type: "vmess")
        ], "Flow-style node lists must parse")
        let multilineFlow = """
        proxies: [
          {name: F1, type: ss},
          {name: "F2", type: http, port: 1}
        ]
        proxy-groups: []
        """
        precondition(SubscriptionParser.nodes(in: multilineFlow).map(\.name) == ["F1", "F2"],
                     "Multi-line flow-style node lists must parse")
        // Comments inside a multi-line flow sequence must not swallow later nodes.
        let commentedFlow = """
        proxies: [ # start
          {name: One, type: ss}, # first
          # middle comment
          {name: Two, type: http, ws-opts: {path: /x, headers: {Host: example.com}}}
        ]
        proxy-groups: []
        """
        precondition(SubscriptionParser.nodes(in: commentedFlow).map(\.name) == ["One", "Two"],
                     "Comments inside flow sequences must be ignored")
        // Detecting node content (used to accept styles the narrow parser cannot name).
        precondition(SubscriptionParser.hasNodeEntries(in: apostrophe))
        precondition(SubscriptionParser.hasNodeEntries(in: flow))
        precondition(SubscriptionParser.hasNodeEntries(in: "proxies:\n  - &anchor {name: A, type: ss}"))
        precondition(SubscriptionParser.hasNodeEntries(in: "proxies: # a comment\n- name: A\n  type: ss"))
        for empty in ["", "proxies: []", "proxies: [ ]", "proxies: null", "proxies: ~",
                      "proxies: [] # empty", "proxies: # only a comment",
                      "rules: []\nproxies:"] {
            precondition(!SubscriptionParser.hasNodeEntries(in: empty), "Unexpected node content: \(empty)")
        }
        // Content that is not a Clash/Mihomo YAML subscription yields no nodes.
        for invalid in ["", "not a subscription", "<html></html>", "proxies: []"] {
            precondition(SubscriptionParser.nodes(in: invalid).isEmpty, "Unexpected nodes for: \(invalid)")
        }
    }

    private static func testSubscriptionConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityISP-subscription-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let provider = directory.appendingPathComponent("subscription.yaml")
        try Data("proxies: []\n".utf8).write(to: provider)

        var settings = ProxySettings()
        settings.useSubscription = true
        settings.subscriptionUseManualProxy = false
        settings.localPort = 17898
        try SettingsValidator.validate(settings)
        let providerConfiguration = try RelayConfiguration.make(
            settings: settings, password: "ignored", subscriptionProviderPath: provider.path,
            controllerSocket: directory.appendingPathComponent("controller.sock").path,
            controllerSecret: "test-secret")
        let subscriptionProvider = (providerConfiguration["proxy-providers"] as? [String: Any])?["SUBSCRIPTION"]
            as? [String: Any]
        precondition(subscriptionProvider?["type"] as? String == "file",
                     "The subscription must load from the app-downloaded private file")
        precondition(subscriptionProvider?["path"] as? String == provider.path)
        precondition(subscriptionProvider?["url"] == nil, "The proxy core must not download the subscription")
        let group = (providerConfiguration["proxy-groups"] as? [[String: Any]])?.first
        precondition(group?["type"] as? String == "url-test", "Empty node selection must auto-select")
        precondition(group?["use"] as? [String] == ["SUBSCRIPTION"])
        precondition((group?["proxies"] as? [String])?.isEmpty == true,
                     "The auto group must not contain a REJECT placeholder")
        precondition((providerConfiguration["proxies"] as? [[String: Any]])?.isEmpty == true)
        precondition(providerConfiguration["mixed-port"] as? Int == settings.localPort)
        precondition(providerConfiguration["external-controller"] as? String == "")
        precondition(providerConfiguration["external-controller-unix"] != nil)
        // mihomo parses this file as YAML: JSON's default "\/" escapes break its parser.
        let serialized = String(decoding: try RelayConfiguration.serialize(providerConfiguration), as: UTF8.self)
        precondition(!serialized.contains("\\/"), "Generated config must not contain escaped slashes: \(serialized)")
        precondition(serialized.contains("https://www.gstatic.com/generate_204"),
                     "Provider health-check URL must keep real slashes")
        let roundTrip = try JSONSerialization.jsonObject(
            with: Data(serialized.utf8)) as? [String: Any]
        precondition(roundTrip?["mixed-port"] as? Int == settings.localPort)
        precondition(roundTrip?["proxy-providers"] != nil)

        // A named node switches the group to an explicit selector.
        settings.subscriptionNode = "HK - 香港综合"
        let selected = try RelayConfiguration.make(
            settings: settings, password: "", subscriptionProviderPath: provider.path,
            controllerSocket: "/tmp/controller.sock", controllerSecret: "test-secret")
        precondition((selected["proxy-groups"] as? [[String: Any]])?.first?["type"] as? String == "select")

        // Missing/relative node files must fail before a relay is ever spawned.
        let invalidProviderPaths: [String?] = [nil, "subscription.yaml"]
        for path in invalidProviderPaths {
            do {
                _ = try RelayConfiguration.make(settings: settings, password: "",
                    subscriptionProviderPath: path, controllerSocket: "/tmp/controller.sock",
                    controllerSecret: "test-secret")
                preconditionFailure("Missing subscription provider file was accepted")
            } catch {}
        }

        // Manual mode keeps the single-proxy shape and never creates a provider.
        settings.useSubscription = false
        settings.subscriptionNode = ""
        settings.server = "proxy.example.com"
        let manual = try RelayConfiguration.make(settings: settings, password: "secret",
            subscriptionProviderPath: nil, controllerSocket: "/tmp/controller.sock",
            controllerSecret: "test-secret")
        precondition(manual["proxy-providers"] == nil && manual["proxy-groups"] == nil)
        precondition((manual["proxies"] as? [[String: Any]])?.count == 1)
        precondition(manual["external-controller-unix"] == nil)
        precondition(manual["keep-alive-idle"] as? Int == 15
                     && manual["keep-alive-interval"] as? Int == 15
                     && manual["disable-keep-alive"] as? Bool == false)
    }

    private static func testChainedConfigurations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityISP-chained-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let provider = directory.appendingPathComponent("subscription.yaml")
        try Data("proxies: []\n".utf8).write(to: provider)

        // Subscription-chained landing requires a valid manual landing proxy.
        var subChained = ProxySettings()
        subChained.useSubscription = true
        subChained.chainManualProxy = true
        try expectFailure("Chained subscription without landing server was accepted") {
            try SettingsValidator.validate(subChained)
        }
        subChained.server = "isp.example.com"
        subChained.port = 12321
        subChained.proxyType = "http"
        subChained.username = "isp-user"
        subChained.subscriptionNode = "RELAY"
        try expectFailure("Reserved node name RELAY was accepted") {
            try SettingsValidator.validate(subChained)
        }
        subChained.subscriptionNode = "US - 01"
        subChained.splitChainedModelTraffic = true
        subChained.directDomains = ["internal.example.org"]
        try SettingsValidator.validate(subChained)

        let subConfig = try RelayConfiguration.make(
            settings: subChained, password: "isp-password", subscriptionProviderPath: provider.path,
            controllerSocket: directory.appendingPathComponent("controller.sock").path,
            controllerSecret: "test-secret")
        let subGroup = (subConfig["proxy-groups"] as? [[String: Any]])?.first
        precondition(subGroup?["name"] as? String == "RELAY" && subGroup?["type"] as? String == "select")
        let subProxies = subConfig["proxies"] as? [[String: Any]] ?? []
        precondition(subProxies.count == 1 && subProxies[0]["name"] as? String == "UPSTREAM"
                     && subProxies[0]["dialer-proxy"] as? String == "RELAY")
        let subRules = subConfig["rules"] as? [String] ?? []
        precondition(subRules.first == "NETWORK,udp,REJECT" && subRules.last == "MATCH,RELAY")
        precondition(subRules.contains("DOMAIN-SUFFIX,googleapis.com,UPSTREAM")
                     && subRules.contains("DOMAIN-SUFFIX,antigravity.google,UPSTREAM")
                     && subRules.contains("DOMAIN-SUFFIX,antigravity-unleash.goog,UPSTREAM")
                     && subRules.contains("DOMAIN-SUFFIX,anthropic.com,UPSTREAM")
                     && subRules.contains("DOMAIN-SUFFIX,openai.com,UPSTREAM")
                     && subRules.contains("DOMAIN,internal.example.org,DIRECT"))

        // Manual + VLESS Reality relay builds RELAY -> UPSTREAM without proxy-providers.
        var vlessChained = ProxySettings()
        vlessChained.useSubscription = false
        vlessChained.useRelayURI = true
        vlessChained.server = "isp.example.com"
        vlessChained.port = 12321
        vlessChained.proxyType = "http"
        vlessChained.username = "isp-user"
        vlessChained.splitChainedModelTraffic = false
        let sampleRelay = "vless://11111111-2222-4333-8444-555555555555@relay.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.amd.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd1234&type=tcp"
        let vlessConfig = try RelayConfiguration.make(
            settings: vlessChained, password: "isp-password", subscriptionProviderPath: nil,
            controllerSocket: "/tmp/controller.sock", controllerSecret: "test-secret",
            relayURI: sampleRelay)
        precondition(vlessConfig["proxy-providers"] == nil && vlessConfig["proxy-groups"] == nil)
        let vlessProxies = vlessConfig["proxies"] as? [[String: Any]] ?? []
        precondition(vlessProxies.count == 2)
        precondition(vlessProxies[0]["name"] as? String == "RELAY" && vlessProxies[0]["type"] as? String == "vless")
        precondition(vlessProxies[1]["name"] as? String == "UPSTREAM" && vlessProxies[1]["dialer-proxy"] as? String == "RELAY")
        precondition((vlessConfig["rules"] as? [String])?.last == "MATCH,UPSTREAM")
        precondition(vlessConfig["keep-alive-idle"] as? Int == 15
                     && vlessConfig["keep-alive-interval"] as? Int == 15
                     && vlessConfig["disable-keep-alive"] as? Bool == false)

        // Non-chained mode must ignore splitChainedModelTraffic so rules never point to a nonexistent RELAY.
        var singleHop = ProxySettings()
        singleHop.server = "proxy.example.com"
        singleHop.splitChainedModelTraffic = true
        precondition(!singleHop.isChained)
        let singleRouting = try RoutingPolicy(settings: singleHop)
        precondition(!singleRouting.splitChainedModelTraffic && singleRouting.rules.last == "MATCH,UPSTREAM")
    }

    private static func testSubscriptionCatalog() throws {
        let secretURL = "https://feed.example.com/c/secret-token"
        let catalog = SubscriptionCatalog(
            urlFingerprint: SubscriptionCatalog.fingerprint(secretURL),
            nodes: [SubscriptionNode(name: "HK - 01", type: "ss")],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoded = String(decoding: try JSONEncoder().encode(catalog), as: UTF8.self)
        precondition(!encoded.contains("secret-token"),
                     "The persisted catalog must not contain the subscription URL/token")
        precondition(encoded.contains(catalog.urlFingerprint))
        precondition(SubscriptionCatalog.fingerprint(secretURL) != SubscriptionCatalog.fingerprint(secretURL + "x"))
        let decoded = try JSONDecoder().decode(SubscriptionCatalog.self, from: Data(encoded.utf8))
        precondition(decoded == catalog)
    }

    private static func testSubscriptionCache() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityISP-cache-" + UUID().uuidString, isDirectory: true)
        let previousHome = ProcessInfo.processInfo.environment["ANTIGRAVITY_ISP_HOME"]
        setenv("ANTIGRAVITY_ISP_HOME", home.path, 1)
        defer {
            if let previousHome { setenv("ANTIGRAVITY_ISP_HOME", previousHome, 1) }
            else { unsetenv("ANTIGRAVITY_ISP_HOME") }
            try? FileManager.default.removeItem(at: home)
        }
        let url = "https://feed.example.com/c/cache-token"
        let otherURL = "https://feed.example.com/c/other"
        let yaml = Data("proxies:\n- {name: HK - 01, type: ss}\n".utf8)
        let otherYAML = Data("proxies:\n- {name: US - 01, type: ss}\n".utf8)
        let userInfo = "download=1; total=2"
        let now = Date()
        let maximumAge = SubscriptionCache.maximumAge
        // Simulate an old cache whose metadata and YAML came from different downloads.
        let legacyMetadata = try JSONSerialization.data(withJSONObject: [
            "urlFingerprint": SubscriptionCatalog.fingerprint(url),
            "fetchedAt": now.timeIntervalSinceReferenceDate,
            "userInfo": userInfo
        ])
        let legacyYAMLFile = home.appendingPathComponent("subscription-cache.yaml")
        let legacyMetadataFile = home.appendingPathComponent("subscription-cache.json")
        try AppPaths.writePrivate(otherYAML, to: legacyYAMLFile)
        try AppPaths.writePrivate(legacyMetadata, to: legacyMetadataFile)
        precondition(SubscriptionCache.load(for: url, maximumAge: maximumAge) == nil,
                     "Unbound legacy cache contents must be ignored")

        SubscriptionCache.store(yaml: yaml, for: url, userInfo: userInfo, now: now)
        let fresh = SubscriptionCache.load(for: url, maximumAge: maximumAge, now: now)
        precondition(fresh?.yaml == yaml, "A fresh cache must be readable")
        precondition(fresh?.userInfo == userInfo && fresh?.fetchedAt == now)
        let entries = try FileManager.default.contentsOfDirectory(atPath: home.path)
        precondition(entries == [AppPaths.subscriptionCacheFile.lastPathComponent],
                     "The replacement must publish a single record and remove the old files")
        let recordData = try Data(contentsOf: AppPaths.subscriptionCacheFile)
        precondition(recordData.range(of: Data("cache-token".utf8)) == nil,
                     "The record must not contain the subscription URL token")
        let permissions = try FileManager.default.attributesOfItem(atPath: AppPaths.subscriptionCacheFile.path)
        precondition(permissions[.posixPermissions] as? Int == 0o600, "The cache must be private")
        precondition(SubscriptionCache.load(for: url, maximumAge: maximumAge,
                                            now: now.addingTimeInterval(maximumAge)) != nil)
        precondition(SubscriptionCache.load(for: url, maximumAge: maximumAge,
                                            now: now.addingTimeInterval(maximumAge + 1)) == nil,
                     "An expired cache must be ignored")
        precondition(SubscriptionCache.load(for: url, maximumAge: maximumAge,
                                            now: now.addingTimeInterval(-1)) == nil,
                     "Clock rollback must not extend the cache lifetime")
        precondition(SubscriptionCache.load(for: otherURL, maximumAge: maximumAge) == nil,
                     "The cache must be scoped to the subscription URL")
        // fetch() must serve a matching cache without touching the network.
        let session = home.appendingPathComponent("session", isDirectory: true)
        let snapshot = try SubscriptionFetcher.fetch(
            url: url, proxy: nil, checkCancellation: {}, into: session,
            useCache: true, progress: { _ in })
        precondition(snapshot.nodes == [SubscriptionNode(name: "HK - 01", type: "ss")])
        precondition(snapshot.userInfo == userInfo)
        let written = try Data(contentsOf: SubscriptionFetcher.subscriptionYAMLURL(in: session))
        precondition(written == yaml, "Cached YAML must be copied to the session directory")

        let sources = [(url, yaml, userInfo), (otherURL, otherYAML, "total=3")]
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let (source, body, usage) = sources[index % sources.count]
            SubscriptionCache.store(yaml: body, for: source, userInfo: usage, now: now)
            for (source, body, usage) in sources {
                if let entry = SubscriptionCache.load(for: source, maximumAge: maximumAge, now: now) {
                    precondition(entry.yaml == body && entry.userInfo == usage,
                                 "Concurrent writes must never bind a provider to another provider's data")
                }
            }
        }
        try AppPaths.writePrivate(Data("incomplete record".utf8), to: AppPaths.subscriptionCacheFile)
        precondition(SubscriptionCache.load(for: url, maximumAge: maximumAge) == nil,
                     "An incomplete cache must be ignored")
        SubscriptionCache.store(yaml: yaml, for: url, userInfo: userInfo)
        SubscriptionCache.clear()
        precondition(SubscriptionCache.load(for: url, maximumAge: maximumAge) == nil)
    }

    private static func testSubscriptionCurlRequest() throws {
        var settings = ProxySettings()
        settings.proxyType = "https"
        settings.server = "proxy.example.com"
        settings.port = 8443
        settings.username = "test-user"
        let proxy = SubscriptionDownloadProxy(settings: settings, password: "p\"a\\ss")
        let request = SubscriptionCurlRequest(url: "https://feed.example.com/c/token", proxy: proxy)
        precondition(request.configText.contains("url = \"https://feed.example.com/c/token\""),
                     "The URL must be written to the private curl config")
        precondition(request.configText.contains("proxy = \"https://proxy.example.com:8443\""))
        precondition(request.configText.contains("proxy-user = \"test-user:p\\\"a\\\\ss\""),
                     "Proxy credentials must be escaped in the curl config value: \(request.configText)")
        for scheme in ["http", "https"] {
            let url = "\(scheme)://feed.example.com/c/token"
            try SettingsValidator.validateSubscriptionURL(url)
            let plain = SubscriptionCurlRequest(url: url, proxy: nil)
            precondition(plain.configText == """
                globoff
                proto = "=http,https"
                proto-redir = "=https"
                url = "\(url)"

                """, "Initial HTTP and HTTPS are allowed, with redirects restricted to HTTPS")
        }
        precondition(SubscriptionCurlRequest.escape("a\"b\\c\nd") == "a\\\"b\\\\c\\nd",
                     "curl config quoting must escape quotes, backslashes and newlines")
    }

    private static func testSubscriptionUsage() throws {
        let summary = SubscriptionUsage.summary(
            fromUserInfo: "upload=100; download=2048; total=1073741824; expire=1893456000",
            now: Date(timeIntervalSince1970: 1_700_000_000))
        precondition(summary.contains("已用 2.1 KB / 1.0 GB"), "Unexpected usage summary: \(summary)")
        precondition(summary.contains("有效期至"), "Usage summary must show the expiry: \(summary)")
        let expired = SubscriptionUsage.summary(
            fromUserInfo: "download=0; total=1024; expire=1000",
            now: Date(timeIntervalSince1970: 1_700_000_000))
        precondition(expired.contains("已过期"), "Expired subscriptions must be reported: \(expired)")
        precondition(SubscriptionUsage.summary(fromUserInfo: "") == "")
        precondition(SubscriptionUsage.summary(fromUserInfo: "total=0") == "")
    }

    private static func testRoutingPolicy() throws {
        var settings = ProxySettings()
        settings.server = "proxy.example.com"
        let empty = try RoutingPolicy(settings: settings)
        precondition(empty.rules == [
            "NETWORK,udp,REJECT", "DOMAIN,api.ipify.org,UPSTREAM", "DOMAIN,www.cloudflare.com,UPSTREAM",
            "DOMAIN,api.myip.com,UPSTREAM", "DOMAIN,ifconfig.me,UPSTREAM", "MATCH,UPSTREAM"
        ], "An empty allowlist must never generate DIRECT rules")

        settings.directDomains = [" Zeta.example.com\n", "alpha.example.com", "ALPHA.EXAMPLE.COM"]
        settings.directDomainSuffixes = [" Static.Example.org ", "assets.example.org", "static.example.org"]
        let routing = try RoutingPolicy(settings: settings)
        precondition(routing.directDomains == ["alpha.example.com", "zeta.example.com"])
        precondition(routing.directDomainSuffixes == ["assets.example.org", "static.example.org"])
        precondition(routing.rules == [
            "NETWORK,udp,REJECT", "DOMAIN,api.ipify.org,UPSTREAM", "DOMAIN,www.cloudflare.com,UPSTREAM",
            "DOMAIN,api.myip.com,UPSTREAM", "DOMAIN,ifconfig.me,UPSTREAM",
            "DOMAIN,alpha.example.com,DIRECT", "DOMAIN,zeta.example.com,DIRECT",
            "DOMAIN-SUFFIX,assets.example.org,DIRECT", "DOMAIN-SUFFIX,static.example.org,DIRECT", "MATCH,UPSTREAM"
        ], "UDP rejection, probe pinning, exact domains, suffixes and fallback must keep their order")

        let invalid = [
            "", " ", "https://docs.example.com", "docs.example.com:443", "docs.example.com/path",
            "user@docs.example.com", "*.example.com", ".example.com", "example.com.", "foo..example.com",
            "bad_label.example.com", "-bad.example.com", "bad-.example.com", "foo.example.com\nbar.example.com",
            "foo\n.example.com", "foo\r.example.com", "foo\u{2028}.example.com",
            "example.com,DIRECT", "例子.com", "127.0.0.1", "127.1", "2130706433", "0177.0.0.1",
            "2001:db8::1", "[::1]", "com", "localhost", "co.uk", "com.cn", "net.au", "org.nz", "co.jp",
            "github.io", "pages.dev", "vercel.app", "s3.amazonaws.com", String(repeating: "a", count: 64) + ".com",
            Array(repeating: String(repeating: "a", count: 63), count: 4).joined(separator: ".")
        ]
        let protected = [
            "google.com", "www.google.com", "accounts.google.co.uk", "google.co.jp", "google.com.hk", "google.cat",
            "google.com.au", "googleapis.com", "generativelanguage.googleapis.com", "googleapis.cn",
            "googleusercontent.com", "lh3.googleusercontent.com", "gstatic.com", "gstatic.cn", "googlevideo.com",
            "ggpht.com", "gvt1.com", "gvt2.com", "run.app", "tenant.run.app", "appspot.com", "tenant.appspot.com",
            "anthropic.com", "api.anthropic.com", "claude.ai", "api.claude.ai", "openai.com", "api.openai.com",
            "chatgpt.com", "auth.chatgpt.com", "  API.OPENAI.COM  ", "app", "ai", "com.ec"
        ]
        for domain in invalid + protected {
            for suffix in [false, true] {
                var sample = ProxySettings()
                sample.server = "proxy.example.com"
                if suffix { sample.directDomainSuffixes = [domain] }
                else { sample.directDomains = [domain] }
                try expectFailure("Invalid direct domain was accepted: \(domain)") {
                    try SettingsValidator.validate(sample)
                }
            }
        }

        // Similar text outside a protected domain's label boundary remains user-controlled.
        let unrelated = [
            "notgoogle.com", "google.com.example.org", "googleapis.com.example.org", "my-openai.com",
            "openai.com.example.org", "anthropic.example.org", "my-run.app", "xn--bcher-kva.example",
            "docs.example.com", "project.github.io"
        ]
        settings.directDomains = unrelated
        settings.directDomainSuffixes = unrelated
        try SettingsValidator.validate(settings)

        let limit = (0..<128).map { "host\($0).example.com" }
        for suffix in [false, true] {
            var sample = ProxySettings()
            sample.server = "proxy.example.com"
            if suffix { sample.directDomainSuffixes = limit + ["HOST0.EXAMPLE.COM"] }
            else { sample.directDomains = limit + ["HOST0.EXAMPLE.COM"] }
            try SettingsValidator.validate(sample)
            if suffix { sample.directDomainSuffixes.append("overflow.example.com") }
            else { sample.directDomains.append("overflow.example.com") }
            try expectFailure("More than 128 distinct routing entries were accepted") {
                try SettingsValidator.validate(sample)
            }
        }
    }

    static func expectFailure(_ reason: String, operation: () throws -> Void) throws {
        do { try operation() }
        catch { return }
        throw UserFacingError(reason)
    }
}
