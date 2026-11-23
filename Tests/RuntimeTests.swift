import AppKit
import Darwin
import Foundation

private struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(message: message) }
}

private func expectFailure(_ fragment: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        try expect(error.localizedDescription.contains(fragment), "Unexpected failure: \(error.localizedDescription)")
        return
    }
    throw TestFailure(message: "Expected failure containing: \(fragment)")
}

private func listener() throws -> (descriptor: Int32, port: Int) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw TestFailure(message: "socket failed") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(descriptor, 8) == 0 else {
        close(descriptor)
        throw TestFailure(message: "bind/listen failed")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard result == 0 else {
        close(descriptor)
        throw TestFailure(message: "getsockname failed")
    }
    return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
}

private func freePort() throws -> Int {
    let value = try listener()
    close(value.descriptor)
    return value.port
}

private func sessionDirectories() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: AppPaths.runtimeDirectory,
                                                includingPropertiesForKeys: [.isDirectoryKey])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}

@main
struct RuntimeTests {
    @MainActor
    static func main() async {
        do {
            try prepare()
            try testConfigurationAndOwnership()
            try testInvalidRoutingDoesNotStart()
            try testOccupiedPort()
            try testApplicationLocator()
            try testPathNormalization()
            try testStaleRelayRecovery()
            try testCancellationAndFailure()
            try testRoutingReload()
            try testIPParsing()
            if CommandLine.arguments.count > 2 {
                try await testApplicationEnvironment(at: URL(fileURLWithPath: CommandLine.arguments[2]))
            }
            print("Runtime tests passed: private config, authentication escaping, allowlist routing, upstream-pinned exit probes, UDP rejection, invalid-routing startup refusal, owned listener, session lock, occupied port, stale-relay recovery, application detection, cancellation, startup failure, routing reload and rollback, cleanup, IP parsing.")
        } catch {
            fputs("Runtime tests failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func prepare() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build", isDirectory: true)
        let home = AppPaths.supportDirectory.standardizedFileURL
        try expect(home.path.hasPrefix(root.standardizedFileURL.path + "/"), "Tests require ANTIGRAVITY_ISP_HOME inside this repository's .build directory")
        try expect(home.lastPathComponent == "runtime-test-home", "Use .build/runtime-test-home for the isolated test home")
        try expect(CommandLine.arguments.count >= 2, "Pass the compiled fake relay path")
        try AppPaths.createPrivateDirectory(home)
        try AppPaths.createPrivateDirectory(AppPaths.mihomoExecutable.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: AppPaths.mihomoExecutable.path) {
            try FileManager.default.removeItem(at: AppPaths.mihomoExecutable)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: AppPaths.mihomoExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppPaths.mihomoExecutable.path)
    }

    private static func settings() throws -> ProxySettings {
        var settings = ProxySettings()
        settings.server = "relay.invalid"
        settings.username = "test-user"
        settings.localPort = try freePort()
        return settings
    }

    private static func testConfigurationAndOwnership() throws {
        var settings = try settings()
        settings.proxyType = "https"
        settings.directDomains = [" Zeta.example.com ", "alpha.example.com", "ALPHA.EXAMPLE.COM", "api.ipify.org", "www.cloudflare.com"]
        settings.directDomainSuffixes = ["ipify.org", "cloudflare.com", " Assets.Example.org ", "assets.example.org"]
        let password = "test-only:\"quote\\slash\n$literal"
        let session = try RelaySession.start(settings: settings, password: password, cancellation: RuntimeCancellation())
        defer { session.stop() }
        try expect(session.isAlive, "Owned listener should be alive")
        let directories = try sessionDirectories()
        try expect(directories.count == 1, "Exactly one session directory is expected")
        let directory = directories[0]
        let configURL = directory.appendingPathComponent("config.json")
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        try expect((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Session mode must be 0700")
        try expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Config mode must be 0600")
        let data = try Data(contentsOf: configURL)
        let config = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let proxy = (config["proxies"] as! [[String: Any]])[0]
        try expect(proxy["password"] as? String == password, "Authentication must survive JSON escaping")
        try expect(proxy["tls"] as? Bool == true, "HTTPS upstream must use TLS")
        try expect(proxy["skip-cert-verify"] == nil, "TLS certificate verification must remain enabled")
        let rules = config["rules"] as? [String] ?? []
        try expect(rules == [
            "NETWORK,udp,REJECT", "DOMAIN,api.ipify.org,UPSTREAM", "DOMAIN,www.cloudflare.com,UPSTREAM",
            "DOMAIN,api.myip.com,UPSTREAM", "DOMAIN,ifconfig.me,UPSTREAM",
            "DOMAIN,alpha.example.com,DIRECT", "DOMAIN,api.ipify.org,DIRECT", "DOMAIN,www.cloudflare.com,DIRECT",
            "DOMAIN,zeta.example.com,DIRECT", "DOMAIN-SUFFIX,assets.example.org,DIRECT",
            "DOMAIN-SUFFIX,cloudflare.com,DIRECT", "DOMAIN-SUFFIX,ipify.org,DIRECT", "MATCH,UPSTREAM"
        ], "Generated config must reject UDP and pin exit probes before normalized explicit DIRECT exceptions")
        let probeRules = RoutingPolicy.exitIPCheckEndpoints.compactMap { URL(string: $0)?.host }
            .map { "DOMAIN,\($0),UPSTREAM" }
        try expect(probeRules.count == 4, "The exit check must have four pinned probes")
        for probeRule in probeRules {
            try expect(rules.firstIndex(of: probeRule).map { $0 < 1 + probeRules.count } == true,
                       "Every actual exit probe endpoint must be pinned before all DIRECT rules")
        }
        try expect(config["bind-address"] as? String == "127.0.0.1", "Only bind loopback")
        try expect(config["external-controller"] as? String == "", "No external controller")
        try expect((config["dns"] as? [String: Bool])?["enable"] == false, "DNS service disabled")
        try expect((config["tun"] as? [String: Bool])?["enable"] == false, "TUN disabled")
        try expectFailure("另一个启动器会话") {
            _ = try RelaySession.start(settings: settings, password: "", cancellation: RuntimeCancellation())
        }
        try expect(session.isAlive, "Second session rejection must preserve the first relay")
        session.stop()
        session.stop()
        try expect(!session.isAlive, "Owned relay must stop")
        try expect(try sessionDirectories().isEmpty, "Owned config directory must be removed")
    }

    private static func testInvalidRoutingDoesNotStart() throws {
        var settings = try settings()
        // The fake child would exit with code 17 if it were ever launched.
        settings.server = "exit.invalid"
        settings.directDomainSuffixes = ["api.openai.com"]
        try expectFailure("模型服务") {
            _ = try RelaySession.start(settings: settings, password: "", cancellation: RuntimeCancellation())
        }
        try expect(try sessionDirectories().isEmpty, "Invalid routing must not leave a runtime session or config")
        settings.directDomainSuffixes = []
        settings.directDomains = ["https://docs.example.com"]
        try expectFailure("完整域名") {
            _ = try RelaySession.start(settings: settings, password: "", cancellation: RuntimeCancellation())
        }
        try expect(try sessionDirectories().isEmpty, "Malformed routing must not leave a runtime session or config")
    }

    private static func testApplicationLocator() throws {
        try expect(ApplicationLocator.isSupported("com.google.antigravity"),
                   "Antigravity must be a supported launch target")
        try expect(ApplicationLocator.isSupported("com.google.antigravity-ide"),
                   "Antigravity IDE must be a supported launch target")
        try expect(!ApplicationLocator.isSupported("com.lbjlaq.antigravity-tools"),
                   "Third-party helper apps must not be offered as launch targets")
        try expect(!ApplicationLocator.isSupported("com.google.antigravity-tools"),
                   "Unrelated com.google.antigravity-prefixed tools must be excluded")
        for application in ApplicationLocator.installedApplications() {
            try expect(ApplicationLocator.isSupported(application.bundleIdentifier),
                       "Every detected application must be a supported edition")
            try expect(ApplicationLocator.isApplication(at: application.url),
                       "Detected applications must be launchable: \(application.url.path)")
            try expect(!application.name.isEmpty, "Detected applications must have a name")
        }
    }

    private static func testPathNormalization() throws {
        // proc_pidpath reports /private/tmp/... while the configured path may be /tmp/...
        let probe = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("antigravity-isp-path-probe-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: probe.path, contents: Data("x".utf8)) else {
            throw TestFailure(message: "Cannot create path-normalization probe in /tmp")
        }
        defer { try? FileManager.default.removeItem(at: probe) }
        try expect(RelaySession.resolvedPath(probe.path)
                    == RelaySession.resolvedPath("/private" + probe.path),
                   "A /private-prefixed path and its /tmp form must compare equal (proc_pidpath form)")
        try expect(RelaySession.resolvedPath("/tmp") == RelaySession.resolvedPath("/private/tmp"),
                   "Symlinked support directories must compare equal")
    }

    private static func testStaleRelayRecovery() throws {
        let port = try freePort()
        let stale = AppPaths.runtimeDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let emptyStale = AppPaths.runtimeDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try AppPaths.createPrivateDirectory(stale)
        try AppPaths.createPrivateDirectory(emptyStale)
        let configURL = stale.appendingPathComponent("config.json")
        let config: [String: Any] = [
            "mixed-port": port,
            "proxies": [["name": "ORPHAN", "type": "http", "server": "relay.invalid", "port": 1]],
            "rules": ["MATCH,DIRECT"]
        ]
        try AppPaths.writePrivate(JSONSerialization.data(withJSONObject: config), to: configURL)
        let orphan = Process()
        orphan.executableURL = AppPaths.mihomoExecutable
        orphan.arguments = ["-d", stale.path, "-f", configURL.path]
        orphan.standardOutput = FileHandle.nullDevice
        orphan.standardError = FileHandle.nullDevice
        try orphan.run()
        defer {
            if orphan.isRunning { kill(orphan.processIdentifier, SIGKILL) }
            orphan.waitUntilExit()
        }
        try waitForListener(port: port)

        var settings = try settings()
        settings.localPort = port
        let session = try RelaySession.start(settings: settings, password: "", cancellation: RuntimeCancellation())
        defer { session.stop() }
        try expect(session.isAlive, "A stale relay must be reconciled before the new session starts")
        try expect(!FileManager.default.fileExists(atPath: stale.path),
                   "Orphaned session directory must be removed")
        try expect(!FileManager.default.fileExists(atPath: emptyStale.path),
                   "Abandoned session directory without a process must be removed")
        try expect(kill(orphan.processIdentifier, 0) != 0,
                   "Orphaned proxy core must be terminated")
    }

    private static func waitForListener(port: Int) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw TestFailure(message: "socket failed") }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(descriptor)
            if result == 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw TestFailure(message: "Fake relay did not start listening on \(port)")
    }

    private static func testOccupiedPort() throws {
        let occupied = try listener()
        defer { close(occupied.descriptor) }
        var settings = try settings()
        settings.localPort = occupied.port
        try expectFailure("已被占用") {
            _ = try RelaySession.start(settings: settings, password: "", cancellation: RuntimeCancellation())
        }
        try expect(fcntl(occupied.descriptor, F_GETFD) >= 0, "Foreign port owner's descriptor must remain open")
        try expect(try sessionDirectories().isEmpty, "Occupied-port failure must clean its session")
    }

    private static func testCancellationAndFailure() throws {
        var settings = try settings()
        settings.server = "exit.invalid"
        try expectFailure("退出码 17") {
            _ = try RelaySession.start(settings: settings, password: "", cancellation: RuntimeCancellation())
        }
        try expect(try sessionDirectories().isEmpty, "Startup failure must clean its session")

        settings.server = "slow.invalid"
        let token = RuntimeCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        let started = Date()
        try expectFailure("取消") {
            _ = try RelaySession.start(settings: settings, password: "", cancellation: token)
        }
        try expect(Date().timeIntervalSince(started) < 3, "Cancellation should promptly stop an owned slow child")
        try expect(try sessionDirectories().isEmpty, "Cancellation must clean its session")
    }

    private static func testRoutingReload() throws {
        let original = try settings()
        let session = try RelaySession.start(settings: original, password: "ReloadTestPassword", cancellation: RuntimeCancellation())
        defer { session.stop() }
        let directory = try sessionDirectories()[0]
        let configURL = directory.appendingPathComponent("config.json")
        let observedURL = directory.appendingPathComponent("observed-rules.json")
        let originalData = try Data(contentsOf: configURL)
        var persistedRules = try RoutingPolicy(settings: original).rules

        var edited = original
        edited.directDomains = ["fail-preflight.example.invalid"]
        let rejected = try RoutingPolicy(settings: edited)
        try expectFailure("退出码 21") {
            _ = try session.prepareRouting(rejected, cancellation: RuntimeCancellation())
        }

        edited.directDomains = ["slow-preflight.example.invalid"]
        let slow = try RoutingPolicy(settings: edited)
        let token = RuntimeCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        try expectFailure("取消") {
            _ = try session.prepareRouting(slow, cancellation: token)
        }
        try expect(try Data(contentsOf: configURL) == originalData, "Failed or cancelled preflight must preserve the original config")
        try expect(!FileManager.default.fileExists(atPath: observedURL.path), "Failed or cancelled preflight must not signal the relay")

        edited.directDomains = ["reload.example.invalid"]
        let updated = try RoutingPolicy(settings: edited)
        let update = try session.prepareRouting(updated, cancellation: RuntimeCancellation())
        defer { update.discard() }
        try session.applyRouting(update) {
            try waitForObservedRules(updated.rules, at: observedURL)
            persistedRules = updated.rules
        }
        let updatedData = try Data(contentsOf: configURL)
        var actual = try JSONSerialization.jsonObject(with: updatedData) as! [String: Any]
        let originalConfig = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]
        try expect(actual["rules"] as? [String] == updated.rules, "The owned config should include the new rules")
        actual["rules"] = originalConfig["rules"]
        try expect((actual as NSDictionary).isEqual(to: originalConfig), "All non-routing config fields must be preserved")
        try expect(persistedRules == updated.rules, "Successful reload must invoke persistence")
        try expect(session.isAlive, "The same relay session must stay alive after reload")
        let permissions = try FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600, "Atomic replacement must keep mode 0600")
        update.discard()

        edited.directDomains = ["rollback.example.invalid"]
        let rollback = try RoutingPolicy(settings: edited)
        let rollbackUpdate = try session.prepareRouting(rollback, cancellation: RuntimeCancellation())
        defer { rollbackUpdate.discard() }
        var sawBeforeRollback = false
        try expectFailure("无法保存分流规则") {
            try session.applyRouting(rollbackUpdate) {
                try waitForObservedRules(rollback.rules, at: observedURL)
                sawBeforeRollback = true
                throw TestFailure(message: "Simulated persistence failure")
            }
        }
        try expect(sawBeforeRollback, "The fixture must see the candidate loaded before simulating a failed save")
        try waitForObservedRules(updated.rules, at: observedURL)
        try expect(try Data(contentsOf: configURL) == updatedData, "Failed persistence must atomically restore the previous bytes")
        try expect(persistedRules == updated.rules, "Failed persistence must keep the previous saved rules")
        try expect(session.canApplyRouting, "Successful rollback must leave routing updates available")
        rollbackUpdate.discard()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try expect(Set(files) == ["config.json", "observed-rules.json"], "No staging config should remain")
    }

    private static func waitForObservedRules(_ rules: [String], at url: URL) throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               (try? JSONDecoder().decode([String].self, from: data)) == rules { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw TestFailure(message: "The owned fixture did not load the expected rules")
    }

    private static func testIPParsing() throws {
        try expect(canonicalIP("203.0.113.7") == "203.0.113.7", "IPv4 parsing")
        try expect(canonicalIP("2001:0db8:0:0:0:0:0:1") == "2001:db8::1", "Canonical IPv6 parsing")
        for invalid in ["", "not-an-ip", "127.0.0.1:80", "999.1.2.3", "203.0.113.7\nextra"] {
            try expect(canonicalIP(invalid) == nil, "Reject invalid IP: \(invalid)")
        }
    }

    @MainActor
    private static func testApplicationEnvironment(at appURL: URL) async throws {
        let outputURL = appURL.deletingLastPathComponent().appendingPathComponent("app-environment.json")
        try? FileManager.default.removeItem(at: outputURL)
        let port = try freePort()
        let app = try await LauncherController.openApplication(at: appURL, port: port)
        defer { if !app.isTerminated { app.terminate() } }
        let runningDeadline = Date().addingTimeInterval(3)
        while !NSWorkspace.shared.runningApplications.contains(where: { $0.processIdentifier == app.processIdentifier })
                && Date() < runningDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: outputURL.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let data = try Data(contentsOf: outputURL)
        let values = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            try expect(values[key] as? String == "http://127.0.0.1:\(port)", "App must inherit \(key)")
        }
        for key in ["ALL_PROXY", "all_proxy"] {
            try expect(values[key] as? String == "socks5h://127.0.0.1:\(port)", "App must inherit \(key)")
        }
        for key in ["NO_PROXY", "no_proxy"] {
            try expect(values[key] as? String == "localhost,127.0.0.1,::1", "App must inherit \(key)")
        }
        let arguments = values["arguments"] as? [String] ?? []
        try expect(arguments.contains("--proxy-server=http://127.0.0.1:\(port)"), "Electron proxy argument")
        try expect(arguments.contains("--disable-quic"), "Electron QUIC disabled")
        try expectFailure("已在运行") {
            try LauncherController.validateApplicationForLaunch(at: appURL)
        }
        var connectionSettings = try settings()
        connectionSettings.appPath = appURL.path
        connectionSettings.server = "exit.invalid"
        let controller = LauncherController()
        var testResult: String?
        controller.onStatusChange = { message, busy in
            if !busy { testResult = message }
        }
        controller.test(settings: connectionSettings, password: "")
        let testDeadline = Date().addingTimeInterval(5)
        while testResult == nil && Date() < testDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try expect(testResult?.contains("退出码 17") == true, "Connection tests must reach the relay while the target application is already running")
        try expect(!app.isTerminated, "Connection tests must preserve the existing application")
        try expect(try sessionDirectories().isEmpty, "Failed connection tests must clean their relay configuration")
        try expect(app.terminate(), "Normal terminate request should be accepted")
        let quitDeadline = Date().addingTimeInterval(5)
        while !app.isTerminated && Date() < quitDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try expect(app.isTerminated, "Fixture app should exit normally")
        print("Native fixture app passed: Launch Services environment/arguments, existing-app launch rejection, independent connection testing, and normal termination.")
    }
}
