import Foundation
import Darwin

struct ProxySettings: Codable, Equatable {
    var appPath = "/Applications/Antigravity.app"
    var server = ""
    var port = 8080
    var proxyType = "http"
    var username = ""
    var localPort = 17898
    var expectedExitIP = ""
    var autoStart = false
    var useSubscription = false
    var subscriptionNode = ""
    var subscriptionUseManualProxy = false
    var directDomains: [String] = []
    var directDomainSuffixes: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case appPath, server, port, proxyType, username, localPort, expectedExitIP, autoStart
        case useSubscription, subscriptionNode, subscriptionUseManualProxy
        case directDomains, directDomainSuffixes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appPath = try values.decode(String.self, forKey: .appPath)
        server = try values.decode(String.self, forKey: .server)
        port = try values.decode(Int.self, forKey: .port)
        proxyType = try values.decode(String.self, forKey: .proxyType)
        username = try values.decode(String.self, forKey: .username)
        localPort = try values.decode(Int.self, forKey: .localPort)
        expectedExitIP = try values.decode(String.self, forKey: .expectedExitIP)
        autoStart = try values.decode(Bool.self, forKey: .autoStart)
        useSubscription = try values.decodeIfPresent(Bool.self, forKey: .useSubscription) ?? false
        subscriptionNode = try values.decodeIfPresent(String.self, forKey: .subscriptionNode) ?? ""
        subscriptionUseManualProxy = try values.decodeIfPresent(Bool.self, forKey: .subscriptionUseManualProxy) ?? false
        // Version 0.1.0 did not persist routing exceptions.
        directDomains = try values.decodeIfPresent([String].self, forKey: .directDomains) ?? []
        directDomainSuffixes = try values.decodeIfPresent([String].self, forKey: .directDomainSuffixes) ?? []
    }
}

struct UserFacingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// An explicit allowlist only. This guardrail is not a complete inventory of model-service domains.
struct RoutingPolicy {
    static let maximumEntriesPerGroup = 128
    // Several independent echo services keep the exit check usable when a node
    // blocks or breaks one of them. Every host is pinned to UPSTREAM below.
    private static let exitIPProbeHosts = ["api.ipify.org", "www.cloudflare.com", "api.myip.com", "ifconfig.me"]
    static let exitIPCheckEndpoints = [
        "https://api.ipify.org", "https://www.cloudflare.com/cdn-cgi/trace",
        "https://api.myip.com", "https://ifconfig.me/ip"
    ]

    let directDomains: [String]
    let directDomainSuffixes: [String]

    init(settings: ProxySettings) throws {
        directDomains = try Self.normalize(settings.directDomains, group: "精确直连域名")
        directDomainSuffixes = try Self.normalize(settings.directDomainSuffixes, group: "直连域名后缀")
    }

    var rules: [String] {
        // UDP must not fall through an unsupported upstream into a DIRECT rule.
        // Pin the probes before user exceptions so the reported exit always tests UPSTREAM.
        ["NETWORK,udp,REJECT"]
            + Self.exitIPProbeHosts.map { "DOMAIN,\($0),UPSTREAM" }
            + directDomains.map { "DOMAIN,\($0),DIRECT" }
            + directDomainSuffixes.map { "DOMAIN-SUFFIX,\($0),DIRECT" }
            + ["MATCH,UPSTREAM"]
    }

    private static func normalize(_ entries: [String], group: String) throws -> [String] {
        var domains = Set<String>()
        for entry in entries {
            let domain = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            let validLabels = labels.allSatisfy {
                $0.range(of: #"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z"#, options: .regularExpression) != nil
            }
            let validTLD = labels.last.map {
                $0.range(of: #"\A(?:[a-z]{2,63}|xn--[a-z0-9-]+)\z"#, options: .regularExpression) != nil
            } ?? false
            guard domain.utf8.count <= 253, labels.count >= 2, validLabels, validTLD,
                  !SettingsValidator.isIPAddress(domain) else {
                throw UserFacingError("\(group)只能填写完整域名，不要包含 URL、端口、路径、通配符或 IP；国际化域名请使用 Punycode。")
            }
            guard !commonPublicSuffixes.contains(domain) else {
                throw UserFacingError("\(group)不能使用公共后缀，请填写自己需要直连的具体域名。")
            }
            guard !protectedModelDomains.contains(where: {
                domain == $0 || domain.hasSuffix("." + $0) || $0.hasSuffix("." + domain)
            }) else {
                throw UserFacingError("\(group)不能包含已知模型服务域名及其父域或子域。")
            }
            domains.insert(domain)
        }
        guard domains.count <= maximumEntriesPerGroup else {
            throw UserFacingError("\(group)去重后最多可填写 \(maximumEntriesPerGroup) 项。")
        }
        return domains.sorted()
    }

    // Country domains from https://www.google.com/supported_domains (2026-11-17).
    // Keep label-boundary comparisons: google.com.example.org is not a Google child domain.
    private static let protectedModelDomains: Set<String> = {
        let googleSuffixes = """
        com ad ae com.af com.ag al am co.ao com.ar as at com.au az ba com.bd be bf bg com.bh bi bj
        com.bn com.bo com.br bs bt co.bw by com.bz ca cd cf cg ch ci co.ck cl cm cn com.co co.cr
        com.cu cv com.cy cz de dj dk dm com.do dz com.ec ee com.eg es com.et fi com.fj fm fr ga ge
        gg com.gh com.gi gl gm gr com.gt gy com.hk hn hr ht hu co.id ie co.il im co.in iq is it je
        com.jm jo co.jp co.ke com.kh ki kg co.kr com.kw kz la com.lb li lk co.ls lt lu lv com.ly
        co.ma md me mg mk ml com.mm mn com.mt mu mv mw com.mx com.my co.mz com.na com.ng com.ni ne
        nl no com.np nr nu co.nz com.om com.pa com.pe com.pg com.ph com.pk pl pn com.pr ps pt com.py
        com.qa ro ru rw com.sa com.sb sc se com.sg sh si sk com.sl sn so sm sr st com.sv td tg co.th
        com.tj tl tm tn to com.tr tt com.tw co.tz com.ua co.ug co.uk com.uy co.uz com.vc co.ve co.vi
        com.vn vu ws rs co.za co.zm co.zw cat
        """
        let roots = [
            "googleapis.com", "googleapis.cn", "googleusercontent.com", "gstatic.com", "gstatic.cn",
            "googlevideo.com", "ggpht.com", "gvt1.com", "gvt2.com", "run.app", "appspot.com",
            "anthropic.com", "claude.ai", "openai.com", "chatgpt.com"
        ]
        return Set(roots + googleSuffixes.split(whereSeparator: { $0.isWhitespace }).map { "google.\($0)" })
    }()

    // Common registry/shared-hosting suffixes, not a full Public Suffix List.
    // Bare TLDs are rejected by the domain-shape check above.
    private static let commonPublicSuffixes: Set<String> = {
        let namespaces = [
            "uk": "ac co gov ltd me net nhs org plc police sch",
            "cn": "ac com edu gov mil net org",
            "au": "asn com edu gov id net org",
            "jp": "ac ad co ed go gr lg ne or",
            "nz": "ac co geek gen govt iwi kiwi maori net org school",
            "in": "ac co com edu firm gen gov ind mil net nic org res",
            "kr": "ac co go mil ne or pe re",
            "hk": "com edu gov idv net org",
            "tw": "club com ebiz edu game gov idv mil net org",
            "sg": "com edu gov net org per",
            "my": "com edu gov mil name net org",
            "br": "com edu gov net org",
            "mx": "com edu gob net org",
            "za": "ac co edu gov law mil net nom org school web",
            "id": "ac biz co desa go mil my net or ponpes sch web",
            "il": "ac co gov idf k12 muni net org",
            "th": "ac co go in mi net or",
            "tr": "av bel biz com dr edu gen gov info k12 kep mil name net org pol tel tsk tv web"
        ]
        var suffixes: Set<String> = [
            "github.io", "gitlab.io", "pages.dev", "workers.dev", "vercel.app", "netlify.app",
            "herokuapp.com", "azurewebsites.net", "cloudfront.net", "s3.amazonaws.com", "blogspot.com"
        ]
        for (country, labels) in namespaces {
            for label in labels.split(separator: " ") { suffixes.insert("\(label).\(country)") }
        }
        return suffixes
    }()
}

enum AppPaths {
    static var supportDirectory: URL {
        // Explicit override is useful for isolated development and integration tests.
        if let override = ProcessInfo.processInfo.environment["ANTIGRAVITY_ISP_HOME"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AntigravityISP", isDirectory: true)
    }
    static var runtimeDirectory: URL { supportDirectory.appendingPathComponent("runtime", isDirectory: true) }
    static var mihomoExecutable: URL { supportDirectory.appendingPathComponent("bin/mihomo") }
    static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var subscriptionCatalogFile: URL { supportDirectory.appendingPathComponent("subscription-nodes.json") }
    static var subscriptionCacheFile: URL { supportDirectory.appendingPathComponent("subscription-cache-v1.plist") }
    static var legacySubscriptionCacheFiles: [URL] {
        ["subscription-cache.yaml", "subscription-cache.json"].map { supportDirectory.appendingPathComponent($0) }
    }

    /// Removes partial subscription downloads left by a node refresh that was
    /// interrupted by quitting or crashing the launcher.
    static func cleanupAbandonedRefreshDirectories() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runtimeDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("node-refresh-") || name.hasPrefix("prefetch-") else { continue }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try createPrivateDirectory(url.deletingLastPathComponent())
        // Set permissions before making the final name visible; never write a world-readable secret.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw UserFacingError("无法创建专用配置文件。")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw UserFacingError("无法保存专用配置文件。")
        }
    }
}

enum SettingsValidator {
    static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    static func validate(_ settings: ProxySettings) throws {
        if !settings.useSubscription || settings.subscriptionUseManualProxy {
            try validateManualProxy(settings)
        }
        guard !["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "UPSTREAM", "DOWNLOAD"].contains(settings.subscriptionNode),
              !settings.subscriptionNode.contains(where: { $0.isNewline }) else {
            throw UserFacingError("请填写订阅中实际的节点名称，不能使用保留名称或换行。")
        }
        guard (1024...65535).contains(settings.localPort) else {
            throw UserFacingError("本机端口须为 1024–65535。")
        }
        guard settings.expectedExitIP.isEmpty || isIPAddress(settings.expectedExitIP) else {
            throw UserFacingError("预期出口请填写有效的 IP 地址；不需要固定出口时留空。")
        }
        guard settings.appPath.hasPrefix("/"), settings.appPath.hasSuffix(".app"),
              !settings.appPath.contains("\n") else {
            throw UserFacingError("请选择 Antigravity.app 的完整路径。")
        }
        _ = try RoutingPolicy(settings: settings)
    }

    private static func validateManualProxy(_ settings: ProxySettings) throws {
        guard ["http", "https", "socks5"].contains(settings.proxyType) else {
            throw UserFacingError("请选择 HTTP、HTTPS 或 SOCKS5 代理。")
        }
        let host = settings.server
        let validDNS = host.range(of: #"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#,
                                  options: .regularExpression) != nil
        guard !host.isEmpty, validDNS || isIPAddress(host),
              !host.contains(".."), !host.contains("\n") else {
            throw UserFacingError("代理服务器请填写 IP 或域名，不要包含协议、端口或账号密码。")
        }
        guard (1...65535).contains(settings.port), (1024...65535).contains(settings.localPort) else {
            throw UserFacingError("上游端口须为 1–65535，本机端口须为 1024–65535。")
        }
        guard !(["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) && settings.port == settings.localPort) else {
            throw UserFacingError("上游代理不能指向本工具自己的本机端口。")
        }
        guard !settings.username.contains(":"), !settings.username.contains("\n"), !settings.username.contains("\r") else {
            throw UserFacingError("代理用户名不能包含冒号或换行。")
        }
    }

    static func validateSubscriptionURL(_ value: String) throws {
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw UserFacingError("请填写完整的 HTTP/HTTPS 订阅链接，不要包含空格、账号密码或 # 片段。")
        }
    }
}
