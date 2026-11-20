import AppKit
import Darwin
import Foundation

/// Owns only the relay and application instance created by this launcher.
@MainActor
final class LauncherController {
    var onStatusChange: ((String, Bool) -> Void)?
    var onStopCompletion: ((Bool) -> Void)?
    private(set) var isRunning = false
    var hasRunningApplication: Bool { application?.isTerminated == false }
    var canApplyRouting: Bool {
        !stopping && operationTask == nil && hasRunningApplication && relay?.canApplyRouting == true
    }

    private var operationTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var cancellation: RuntimeCancellation?
    private var relay: RelaySession?
    private var application: NSRunningApplication?
    private var stopping = false

    func start(settings: ProxySettings, password: String) {
        begin(settings: settings, password: password, launchApplication: true)
    }

    func test(settings: ProxySettings, password: String) {
        begin(settings: settings, password: password, launchApplication: false)
    }

    func applyRouting(_ routing: RoutingPolicy, persist: @escaping () throws -> Void) {
        guard canApplyRouting, let session = relay else { return }
        let token = RuntimeCancellation()
        cancellation = token
        operationTask = Task { [weak self] in
            guard let self else { return }
            let message: String
            do {
                let update = try await Task.detached(priority: .userInitiated) {
                    try session.prepareRouting(routing, cancellation: token)
                }.value
                defer { update.discard() }
                try token.check()
                guard self.hasRunningApplication else {
                    throw RuntimeFailure("Antigravity 已退出，分流规则未更新。")
                }
                try session.applyRouting(update, persist: persist)
                message = "分流规则已保存，已请求本地代理重新加载。已有连接可能需要重新连接。"
            } catch {
                message = error.localizedDescription
            }
            self.operationTask = nil
            self.cancellation = nil
            if !self.stopping { self.report(message, busy: true) }
        }
        report("正在检查新的分流规则…", busy: true)
    }

    func showApplication() {
        application?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    /// Asks the application to quit normally. A refusal leaves its relay available.
    func stop() {
        guard stopTask == nil else { return }
        guard isRunning else {
            Task { [weak self] in self?.onStopCompletion?(true) }
            return
        }
        stopping = true
        cancellation?.cancel()
        monitorTask?.cancel()
        monitorTask = nil
        report("正在停止，请等待应用正常退出…", busy: true)
        stopTask = Task { [weak self] in
            guard let self else { return }
            if let operation = self.operationTask {
                await operation.value
            }
            if let app = self.application, !app.isTerminated {
                guard app.terminate() else {
                    self.finishRefusedStop()
                    return
                }
                let deadline = Date().addingTimeInterval(10)
                while !app.isTerminated && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard app.isTerminated else {
                    self.finishRefusedStop()
                    return
                }
            }
            self.application = nil
            await self.cleanRelay()
            self.cancellation = nil
            self.stopping = false
            self.stopTask = nil
            self.report("已停止，临时代理配置已清理。", busy: false)
            self.onStopCompletion?(true)
        }
    }

    private func begin(settings: ProxySettings, password: String, launchApplication: Bool) {
        guard !isRunning && operationTask == nil && stopTask == nil else {
            report("已有启动、测试或应用会话，请先停止当前会话。", busy: true)
            return
        }
        do {
            try SettingsValidator.validate(settings)
            if launchApplication {
                guard let bundle = Bundle(url: URL(fileURLWithPath: settings.appPath)),
                      let executable = bundle.executableURL,
                      FileManager.default.isExecutableFile(atPath: executable.path) else {
                    throw RuntimeFailure("所选应用缺少可执行文件，请选择完整的 Antigravity.app。")
                }
            }
            try Self.requireApplicationClosed(at: URL(fileURLWithPath: settings.appPath))
        } catch {
            report(error.localizedDescription, busy: false)
            return
        }
        let token = RuntimeCancellation()
        cancellation = token
        report(launchApplication ? "正在启动本地代理并检查出口…" : "正在测试代理连接…", busy: true)
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.stopping { self.operationTask = nil }
            }
            do {
                let session = try await Task.detached(priority: .userInitiated) {
                    try RelaySession.start(settings: settings, password: password, cancellation: token)
                }.value
                self.relay = session
                try token.check()
                let exitIP = try await Task.detached(priority: .userInitiated) {
                    try session.checkExitIP(expected: settings.expectedExitIP, cancellation: token)
                }.value
                try token.check()
                guard session.isAlive else { throw RuntimeFailure("本地代理在检查期间意外退出。") }

                if launchApplication {
                    let appURL = URL(fileURLWithPath: settings.appPath)
                    try Self.requireApplicationClosed(at: appURL)
                    self.report("出口 IP：\(exitIP)，正在启动 Antigravity…", busy: true)
                    let app = try await Self.openApplication(at: appURL, port: settings.localPort)
                    self.application = app
                    try token.check()
                    // Launch Services may return before Electron fails during startup.
                    for _ in 0..<15 {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        try token.check()
                        guard !app.isTerminated else {
                            throw RuntimeFailure("Antigravity 启动后立即退出，请检查应用安装或应用自身的错误。")
                        }
                        guard session.isAlive else {
                            throw RuntimeFailure("本地代理意外退出；Antigravity 仍在运行，请正常退出应用后重试。")
                        }
                    }
                    self.operationTask = nil
                    self.cancellation = nil
                    self.report("Antigravity 已启动 · 出口 IP：\(exitIP)", busy: true)
                    self.startMonitoring()
                } else {
                    await self.cleanRelay()
                    try token.check()
                    self.operationTask = nil
                    self.cancellation = nil
                    self.report("测试成功 · 出口 IP：\(exitIP)", busy: false)
                }
            } catch {
                // stop() waits for this task, then handles any application returned
                // concurrently by Launch Services before removing its proxy.
                if self.stopping { return }
                if let app = self.application, !app.isTerminated {
                    self.operationTask = nil
                    self.cancellation = nil
                    self.report(error.localizedDescription, busy: true)
                    self.startMonitoring()
                } else {
                    self.application = nil
                    await self.cleanRelay()
                    if self.stopping { return }
                    self.operationTask = nil
                    self.cancellation = nil
                    self.report(error.localizedDescription, busy: false)
                }
            }
        }
    }

    private func finishRefusedStop() {
        stopping = false
        stopTask = nil
        report("应用尚未退出。请处理应用中的保存或退出提示；本地代理继续保留。", busy: true)
        startMonitoring()
        onStopCompletion?(false)
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, !self.stopping else { return }
                guard self.operationTask == nil else { continue }
                if self.application?.isTerminated != false {
                    self.application = nil
                    await self.cleanRelay()
                    self.cancellation = nil
                    self.report("应用已退出，临时代理配置已清理。", busy: false)
                    return
                }
                if let session = self.relay, !session.isAlive {
                    await self.cleanRelay()
                    self.report("本地代理意外退出；Antigravity 仍在运行，请退出应用后重新启动。", busy: true)
                }
            }
        }
    }

    private func cleanRelay() async {
        guard let session = relay else { return }
        relay = nil
        await Task.detached(priority: .userInitiated) { session.stop() }.value
    }

    private func report(_ message: String, busy: Bool) {
        isRunning = busy
        onStatusChange?(message, busy)
    }

    private static func requireApplicationClosed(at url: URL) throws {
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
        let identifier = Bundle(url: url)?.bundleIdentifier
        let existing = NSWorkspace.shared.runningApplications.contains { app in
            guard !app.isTerminated else { return false }
            if let appURL = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL,
               appURL == normalized { return true }
            return identifier != nil && app.bundleIdentifier == identifier
        }
        if existing {
            throw RuntimeFailure("Antigravity 已在运行。请先正常退出，再通过本工具启动或测试；本工具不会结束已有应用。")
        }
    }

    static func openApplication(at url: URL, port: Int) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [
            "--proxy-server=http://127.0.0.1:\(port)",
            "--proxy-bypass-list=localhost;127.0.0.1;[::1]",
            "--disable-quic"
        ]
        var environment = ProcessInfo.processInfo.environment
        let httpProxy = "http://127.0.0.1:\(port)"
        let socksProxy = "socks5h://127.0.0.1:\(port)"
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            environment[key] = httpProxy
        }
        for key in ["ALL_PROXY", "all_proxy"] { environment[key] = socksProxy }
        for key in ["NO_PROXY", "no_proxy"] { environment[key] = "localhost,127.0.0.1,::1" }
        configuration.environment = environment
        let requestedAt = Date()
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error {
                    continuation.resume(throwing: RuntimeFailure("无法启动 Antigravity：\(error.localizedDescription)"))
                } else if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: RuntimeFailure("Launch Services 未返回应用进程。"))
                }
            }
        }
        // Never claim ownership of a pre-existing instance returned by Launch Services.
        if let launchDate = app.launchDate, launchDate < requestedAt.addingTimeInterval(-1) {
            throw RuntimeFailure("检测到已有 Antigravity 实例，无法确认代理环境已应用。请退出该实例后重试。")
        }
        return app
    }
}

private struct RuntimeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class RuntimeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw RuntimeFailure("操作已取消。") }
    }
}

/// No PID files or discovery of foreign processes are used for cleanup.
final class RelaySession: @unchecked Sendable {
    private let process = Process()
    private let stopLock = NSLock()
    private let directory: URL
    private let port: Int
    private var lockDescriptor: Int32
    private var stopped = false
    private var routingRollbackFailed = false

    var isAlive: Bool { process.isRunning }
    var canApplyRouting: Bool { !routingRollbackFailed && isAlive }
    private var configURL: URL { directory.appendingPathComponent("config.json") }

    private init(directory: URL, port: Int, lockDescriptor: Int32) {
        self.directory = directory
        self.port = port
        self.lockDescriptor = lockDescriptor
    }

    static func start(settings: ProxySettings, password: String, cancellation: RuntimeCancellation) throws -> RelaySession {
        try cancellation.check()
        // Validate here as well as in the UI so every caller fails before spawning a relay.
        try SettingsValidator.validate(settings)
        let routing = try RoutingPolicy(settings: settings)
        guard FileManager.default.isExecutableFile(atPath: AppPaths.mihomoExecutable.path) else {
            throw RuntimeFailure("未找到可执行的 Mihomo，请先安装代理内核。")
        }
        try makePrivateDirectory(AppPaths.runtimeDirectory)
        let lockURL = AppPaths.runtimeDirectory.appendingPathComponent("launcher.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RuntimeFailure("无法创建运行锁。") }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0,
              lockInfo.st_uid == getuid(),
              (lockInfo.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw RuntimeFailure("另一个启动器会话正在运行，或运行锁不可用。")
        }
        let directory = AppPaths.runtimeDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw error
        }
        let session = RelaySession(directory: directory, port: settings.localPort, lockDescriptor: descriptor)
        do {
            try session.writeConfiguration(settings: settings, password: password, routing: routing)
            try session.requireFreePort()
            try cancellation.check()
            session.process.executableURL = AppPaths.mihomoExecutable
            session.process.arguments = ["-d", directory.path, "-f", session.configURL.path]
            session.process.currentDirectoryURL = directory
            session.process.standardInput = FileHandle.nullDevice
            session.process.standardOutput = FileHandle.nullDevice
            session.process.standardError = FileHandle.nullDevice
            // A fresh, non-secret environment also keeps inherited proxy settings
            // from recursively redirecting the relay's own upstream connection.
            session.process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            try session.process.run()
            try session.waitUntilListening(cancellation: cancellation)
            return session
        } catch {
            session.stop()
            throw error
        }
    }

    private func writeConfiguration(settings: ProxySettings, password: String, routing: RoutingPolicy) throws {
        var upstream: [String: Any] = [
            "name": "UPSTREAM", "type": settings.proxyType == "socks5" ? "socks5" : "http",
            "server": settings.server, "port": settings.port, "udp": false
        ]
        if settings.proxyType == "https" { upstream["tls"] = true }
        if !settings.username.isEmpty {
            upstream["username"] = settings.username
            upstream["password"] = password
        }
        let configuration: [String: Any] = [
            "mixed-port": port, "port": 0, "socks-port": 0, "redir-port": 0, "tproxy-port": 0,
            "allow-lan": false, "bind-address": "127.0.0.1", "ipv6": false,
            "mode": "rule", "log-level": "silent", "external-controller": "",
            "profile": ["store-selected": false, "store-fake-ip": false],
            "tun": ["enable": false], "dns": ["enable": false],
            "proxies": [upstream], "rules": routing.rules
        ]
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        try writeConfigurationData(data, to: configURL)
    }

    func prepareRouting(_ routing: RoutingPolicy, cancellation: RuntimeCancellation) throws -> RelayRoutingUpdate {
        try cancellation.check()
        guard isAlive else { throw RuntimeFailure("本地代理已退出，分流规则未更新。") }
        let currentData = try Data(contentsOf: configURL)
        guard var candidate = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
            throw RuntimeFailure("无法读取当前会话的配置，分流规则未更新。")
        }
        candidate["rules"] = routing.rules
        let data = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
        let identifier = UUID().uuidString
        let update = RelayRoutingUpdate(
            candidate: directory.appendingPathComponent("routing-\(identifier).json"),
            previous: directory.appendingPathComponent("previous-\(identifier).json")
        )
        do {
            try writeConfigurationData(data, to: update.candidate)
            let checked = try RuntimeCommand.run(
                executable: AppPaths.mihomoExecutable.path,
                arguments: ["-t", "-d", directory.path, "-f", update.candidate.path],
                timeout: 10, cancellation: cancellation, captureOutput: false
            )
            try cancellation.check()
            guard checked.status == 0 else {
                throw RuntimeFailure(checked.status == -1
                    ? "Mihomo 检查分流规则超时，原配置继续使用。"
                    : "Mihomo 检查分流规则失败（退出码 \(checked.status)），原配置继续使用。")
            }
            // Keep an atomic rollback path without writing a second copy of the credentials.
            guard link(configURL.path, update.previous.path) == 0 else {
                throw RuntimeFailure("无法保留当前会话的配置，分流规则未更新。")
            }
            return update
        } catch {
            update.discard()
            throw error
        }
    }

    /// The controller serializes this short commit and persistence step with stop and monitoring.
    func applyRouting(_ update: RelayRoutingUpdate, persist: () throws -> Void) throws {
        guard canApplyRouting else { throw RuntimeFailure("当前会话无法更新分流规则。") }
        guard rename(update.candidate.path, configURL.path) == 0 else {
            throw RuntimeFailure("无法替换当前会话的配置，分流规则未更新。")
        }
        var reloadRequested = false
        do {
            try requestRoutingReload()
            reloadRequested = true
            do { try persist() }
            catch { throw RuntimeFailure("无法保存分流规则，已恢复上一次配置并请求重新加载。") }
        } catch {
            // Mihomo reads the same path on SIGHUP. If persistence failed, make
            // that path point at the old config before requesting another reload.
            guard rename(update.previous.path, configURL.path) == 0 else {
                routingRollbackFailed = true
                throw RuntimeFailure("分流规则未保存，无法恢复会话配置。请退出 Antigravity 后重新启动。")
            }
            if reloadRequested {
                do { try requestRoutingReload() }
                catch {
                    routingRollbackFailed = true
                    throw RuntimeFailure("分流规则未保存，无法请求代理重新加载原配置。请退出 Antigravity 后重新启动。")
                }
            }
            throw error
        }
    }

    private func requestRoutingReload() throws {
        guard process.isRunning, kill(process.processIdentifier, SIGHUP) == 0 else {
            throw RuntimeFailure("无法请求本地代理重新加载，分流规则未保存。")
        }
    }

    private func writeConfigurationData(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RuntimeFailure("无法创建私有代理配置。") }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RuntimeFailure("写入代理配置失败。") }
                offset += count
            }
        }
    }

    private func requireFreePort() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RuntimeFailure("无法检查本地端口。") }
        defer { close(descriptor) }
        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            throw RuntimeFailure("本地端口 \(port) 已被占用或不可绑定。请更换端口；本工具不会结束占用端口的进程。")
        }
    }

    private func waitUntilListening(cancellation: RuntimeCancellation) throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try cancellation.check()
            guard process.isRunning else {
                throw RuntimeFailure("Mihomo 启动失败（退出码 \(process.terminationStatus)）。请检查代理配置和内核版本。")
            }
            // Verify that our child owns the listening socket, not a process that
            // raced to claim the port after the availability check.
            let result = try RuntimeCommand.run(
                executable: "/usr/sbin/lsof",
                arguments: ["-nP", "-a", "-p", String(process.processIdentifier), "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "p"],
                timeout: 2, cancellation: cancellation
            )
            if result.status == 0,
               result.output.split(separator: "\n").contains(Substring("p\(process.processIdentifier)")),
               process.isRunning {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw RuntimeFailure("Mihomo 未能在 8 秒内监听本地端口。")
    }

    func checkExitIP(expected: String, cancellation: RuntimeCancellation) throws -> String {
        let deadline = Date().addingTimeInterval(20)
        var detectedIP: String?
        for endpoint in RoutingPolicy.exitIPCheckEndpoints {
            try cancellation.check()
            guard isAlive else { throw RuntimeFailure("本地代理已退出。") }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.2 else { break }
            let result = try RuntimeCommand.run(
                executable: "/usr/bin/curl",
                arguments: ["-q", "--silent", "--show-error", "--fail", "--connect-timeout", "8",
                            "--max-time", String(format: "%.1f", remaining), "--max-filesize", "16384",
                            "--proxy", "http://127.0.0.1:\(port)", "--noproxy", "", endpoint],
                timeout: remaining + 0.5, cancellation: cancellation
            )
            guard result.status == 0 else { continue }
            let value: String
            if endpoint.contains("cloudflare") {
                value = result.output.split(separator: "\n").first(where: { $0.hasPrefix("ip=") })
                    .map { String($0.dropFirst(3)) } ?? ""
            } else {
                value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let canonical = canonicalIP(value) {
                detectedIP = canonical
                break
            }
        }
        guard let detectedIP else {
            throw RuntimeFailure("代理出口检查失败。请核对上游地址、端口、认证和网络连通性（超时 20 秒）。")
        }
        let trimmedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExpected.isEmpty {
            guard let normalizedExpected = canonicalIP(trimmedExpected) else {
                throw RuntimeFailure("预期出口 IP 格式无效。")
            }
            guard detectedIP == normalizedExpected else {
                throw RuntimeFailure("出口 IP 不匹配：实际 \(detectedIP)，预期 \(normalizedExpected)。已取消启动。")
            }
        }
        return detectedIP
    }

    func stop() {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !stopped else { return }
        stopped = true
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                // Only the Process object launched by this session is addressed.
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    deinit { stop() }
}

struct RelayRoutingUpdate: Sendable {
    fileprivate let candidate: URL
    fileprivate let previous: URL

    func discard() {
        try? FileManager.default.removeItem(at: candidate)
        try? FileManager.default.removeItem(at: previous)
    }
}

private enum RuntimeCommand {
    static func run(executable: String, arguments: [String], timeout: TimeInterval,
                    cancellation: RuntimeCancellation, captureOutput: Bool = true) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = captureOutput ? Pipe() : nil
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output as Any? ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try cancellation.check()
        try process.run()
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        do {
            while process.isRunning {
                try cancellation.check()
                if Date() >= deadline {
                    stopOwnedCommand(process)
                    return (-1, "")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } catch {
            stopOwnedCommand(process)
            throw error
        }
        guard let output else { return (process.terminationStatus, "") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 65_536 else { return (-1, "") }
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func stopOwnedCommand(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

private func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    var info = stat()
    guard lstat(url.path, &info) == 0,
          info.st_uid == getuid(),
          (info.st_mode & S_IFMT) == S_IFDIR,
          chmod(url.path, 0o700) == 0 else {
        throw RuntimeFailure("运行目录必须是当前用户拥有的普通私有目录。")
    }
}

private func loopbackAddress(port: Int) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return address
}

func canonicalIP(_ text: String) -> String? {
    var ipv4 = in_addr()
    if text.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }
    var ipv6 = in6_addr()
    if text.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }
    return nil
}
