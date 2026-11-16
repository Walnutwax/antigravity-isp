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
}

struct UserFacingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
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
        guard settings.expectedExitIP.isEmpty || isIPAddress(settings.expectedExitIP) else {
            throw UserFacingError("预期出口请填写有效的 IP 地址；不需要固定出口时留空。")
        }
        guard settings.appPath.hasPrefix("/"), settings.appPath.hasSuffix(".app"),
              !settings.appPath.contains("\n") else {
            throw UserFacingError("请选择 Antigravity.app 的完整路径。")
        }
        guard !settings.username.contains(":"), !settings.username.contains("\n"), !settings.username.contains("\r") else {
            throw UserFacingError("代理用户名不能包含冒号或换行。")
        }
    }
}
