import Foundation
import Darwin

@main
struct ModelTests {
    static func main() throws {
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
        precondition(!CoreInstaller.verifiedArchive(Data("modified archive".utf8)))

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
        print("PASS: invalid configurations, self-proxy loop, password-free settings, legacy migration, routing guardrails/order, tampered core, private atomic writes")
    }

    private static func testSettingsMigration() throws {
        // Literal 0.1.0 schema: this must not depend on the current encoder's fields.
        let legacy = Data(#"{"appPath":"/Applications/Antigravity.app","server":"proxy.example.com","port":8443,"proxyType":"https","username":"test-user","localPort":17899,"expectedExitIP":"203.0.113.7","autoStart":true}"#.utf8)
        var settings = try JSONDecoder().decode(ProxySettings.self, from: legacy)
        precondition(settings.directDomains.isEmpty && settings.directDomainSuffixes.isEmpty)
        precondition(settings.server == "proxy.example.com" && settings.port == 8443)
        precondition(settings.username == "test-user" && settings.localPort == 17899)
        precondition(settings.proxyType == "https" && settings.expectedExitIP == "203.0.113.7" && settings.autoStart)
        try SettingsValidator.validate(settings)

        settings.directDomains = ["docs.example.com", "downloads.example.net"]
        settings.directDomainSuffixes = ["assets.example.org"]
        let updated = try JSONEncoder().encode(settings)
        let roundTrip = try JSONDecoder().decode(ProxySettings.self, from: updated)
        precondition(roundTrip == settings, "Routing exceptions must survive settings persistence")
        let fields = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
        precondition(fields["directDomains"] as? [String] == settings.directDomains)
        precondition(fields["directDomainSuffixes"] as? [String] == settings.directDomainSuffixes)
        precondition(fields["password"] == nil, "Migration must not introduce persisted passwords")
    }

    private static func testRoutingPolicy() throws {
        var settings = ProxySettings()
        settings.server = "proxy.example.com"
        let empty = try RoutingPolicy(settings: settings)
        precondition(empty.rules == [
            "NETWORK,udp,REJECT", "DOMAIN,api.ipify.org,UPSTREAM",
            "DOMAIN,www.cloudflare.com,UPSTREAM", "MATCH,UPSTREAM"
        ], "An empty allowlist must never generate DIRECT rules")

        settings.directDomains = [" Zeta.example.com\n", "alpha.example.com", "ALPHA.EXAMPLE.COM"]
        settings.directDomainSuffixes = [" Static.Example.org ", "assets.example.org", "static.example.org"]
        let routing = try RoutingPolicy(settings: settings)
        precondition(routing.directDomains == ["alpha.example.com", "zeta.example.com"])
        precondition(routing.directDomainSuffixes == ["assets.example.org", "static.example.org"])
        precondition(routing.rules == [
            "NETWORK,udp,REJECT", "DOMAIN,api.ipify.org,UPSTREAM", "DOMAIN,www.cloudflare.com,UPSTREAM",
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
