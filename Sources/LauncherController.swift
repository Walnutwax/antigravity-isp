import AppKit
import Darwin
import Foundation

/// Owns the application, relay and optional theme daemon created by this launcher.
@MainActor
final class LauncherController {
    var onStatusChange: ((String, Bool) -> Void)?
    var onStopCompletion: ((Bool) -> Void)?
    /// Reports the node catalog of a successful subscription relay so the picker can be refreshed.
    var onSubscriptionNodes: (([String]) -> Void)?
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
    private var theme: ThemeSession?
    private var application: NSRunningApplication?
    private var stopping = false

    func start(settings: ProxySettings, password: String, subscriptionURL: String = "", relayURI: String = "") {
        begin(settings: settings, password: password, subscriptionURL: subscriptionURL, relayURI: relayURI, launchApplication: true)
    }

    func test(settings: ProxySettings, password: String, subscriptionURL: String = "", relayURI: String = "") {
        begin(settings: settings, password: password, subscriptionURL: subscriptionURL, relayURI: relayURI, launchApplication: false)
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
        let monitor = monitorTask
        monitor?.cancel()
        monitorTask = nil
        report("正在停止，请等待应用正常退出…", busy: true)
        stopTask = Task { [weak self] in
            guard let self else { return }
            if let operation = self.operationTask {
                await operation.value
            }
            if let monitor { await monitor.value }
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
            await self.cleanRuntime()
            self.cancellation = nil
            self.stopping = false
            self.stopTask = nil
            self.report("已停止，临时代理配置已清理。", busy: false)
            self.onStopCompletion?(true)
        }
    }

    private func begin(settings: ProxySettings, password: String, subscriptionURL: String, relayURI: String, launchApplication: Bool) {
        guard !isRunning && operationTask == nil && stopTask == nil else {
            report("已有启动、测试或应用会话，请先停止当前会话。", busy: true)
            return
        }
        do {
            try SettingsValidator.validate(settings)
            if settings.useSubscription { try SettingsValidator.validateSubscriptionURL(subscriptionURL) }
            if !settings.useSubscription && settings.useRelayURI {
                _ = try VlessRelayURI(relayURI, localPort: settings.localPort)
            }
            if launchApplication {
                try Self.validateApplicationForLaunch(at: URL(fileURLWithPath: settings.appPath))
            }
        } catch {
            report(error.localizedDescription, busy: false)
            return
        }
        let token = RuntimeCancellation()
        cancellation = token
        let startedAt = Date()
        report(settings.useSubscription ? "正在获取订阅…" : (launchApplication ? "正在启动本地代理并检查出口…" : "正在测试代理连接…"), busy: true)
        let progress: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                // Ignore a late progress hop once this operation has finished, so it
                // cannot leave the UI stuck on a stale "busy" status.
                guard let self, !self.stopping, self.operationTask != nil else { return }
                self.report(message, busy: true)
            }
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.stopping { self.operationTask = nil }
            }
            do {
                let session = try await Task.detached(priority: .userInitiated) {
                    try RelaySession.start(settings: settings, password: password, subscriptionURL: subscriptionURL,
                                           relayURI: relayURI, progress: progress, cancellation: token)
                }.value
                self.relay = session
                try token.check()
                if settings.useSubscription, !session.subscriptionNodes.isEmpty {
                    self.onSubscriptionNodes?(session.subscriptionNodes)
                }
                let subscriptionStatus = session.subscriptionNodeCount > 0 ? "订阅 \(session.subscriptionNodeCount) 个节点 · " : ""
                self.report(subscriptionStatus + "正在检查代理出口…", busy: true)
                let exitIP: String
                do {
                    exitIP = try await Task.detached(priority: .userInitiated) {
                        try session.checkExitIP(expected: settings.expectedExitIP, cancellation: token)
                    }.value
                } catch {
                    if settings.useSubscription {
                        let hint = settings.subscriptionNode.isEmpty
                            ? "自动选择的节点无法连通。请在“节点”中手动选择一个可用节点后重试。"
                            : "所选节点“\(settings.subscriptionNode)”无法连通。请在“节点”中换一个节点后重试。"
                        throw RuntimeFailure("\(error.localizedDescription)\n\(hint)")
                    }
                    throw error
                }
                try token.check()
                guard session.isAlive else { throw RuntimeFailure("本地代理在检查期间意外退出。") }

                if launchApplication {
                    let appURL = URL(fileURLWithPath: settings.appPath)
                    var themeStatus = ""
                    var themeConfiguration: ThemeSession.Configuration?
                    if settings.themeEnabled, ThemeSession.supportsApplication(at: appURL) {
                        self.report("正在检查 Codex 主题运行环境…", busy: true)
                        do {
                            themeConfiguration = try await Task.detached(priority: .userInitiated) {
                                try ThemeSession.prepare(nodePath: settings.themeNodePath, cancellation: token)
                            }.value
                        } catch {
                            try token.check()
                            themeStatus = " · Codex 主题未启用：\(error.localizedDescription)"
                        }
                    }
                    try Self.requireApplicationClosed(at: appURL)
                    try token.check()
                    guard session.isAlive else { throw RuntimeFailure("本地代理在启动应用前意外退出。") }
                    self.report("出口 IP：\(exitIP)，正在启动 Antigravity…", busy: true)
                    let themeDiscovery = themeConfiguration.map { _ in ThemeEndpointDiscovery() }
                    let app = try await Self.openApplication(at: appURL, port: settings.localPort,
                                                             enableTheme: themeDiscovery != nil)
                    self.application = app
                    try token.check()
                    // Launch Services may return before Electron fails during startup.
                    for _ in 0..<15 {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        try token.check()
                        try Self.requireLaunchedSession(app, relay: session)
                    }
                    if let themeConfiguration, let themeDiscovery {
                        self.report("正在启动 Codex 主题服务…", busy: true)
                        let applicationPID = app.processIdentifier
                        do {
                            self.theme = try await Task.detached(priority: .userInitiated) {
                                try ThemeSession.start(configuration: themeConfiguration, discovery: themeDiscovery,
                                                       applicationPID: applicationPID, relay: session, cancellation: token)
                            }.value
                            themeStatus = " · Codex 主题服务已启动"
                        } catch {
                            themeStatus = " · Codex 主题未启用：\(error.localizedDescription)"
                        }
                        try token.check()
                        try Self.requireLaunchedSession(app, relay: session)
                    }
                    self.operationTask = nil
                    self.cancellation = nil
                    self.report("Antigravity 已启动 · " + subscriptionStatus + "出口 IP：\(exitIP) · 耗时 \(Self.elapsed(since: startedAt)) 秒" + themeStatus, busy: true)
                    self.startMonitoring()
                } else {
                    await self.cleanRuntime()
                    try token.check()
                    self.operationTask = nil
                    self.cancellation = nil
                    self.report("测试成功 · " + subscriptionStatus + "出口 IP：\(exitIP) · 耗时 \(Self.elapsed(since: startedAt)) 秒", busy: false)
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
                    await self.cleanRuntime()
                    if self.stopping { return }
                    self.operationTask = nil
                    self.cancellation = nil
                    self.report(error.localizedDescription, busy: false)
                }
            }
        }
    }

    private static func requireLaunchedSession(_ app: NSRunningApplication, relay: RelaySession) throws {
        guard !app.isTerminated else {
            throw RuntimeFailure("Antigravity 在启动期间退出，请检查应用安装或应用自身的错误。")
        }
        guard relay.isAlive else {
            throw RuntimeFailure("本地代理意外退出，Antigravity 仍在运行，请正常退出应用后重试。")
        }
    }

    private static func elapsed(since date: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(date))
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
                    await self.cleanRuntime()
                    guard !Task.isCancelled, !self.stopping else { return }
                    self.cancellation = nil
                    self.report("应用已退出，临时代理配置已清理。", busy: false)
                    return
                }
                if let session = self.relay, !session.isAlive {
                    await self.cleanRuntime()
                    guard !Task.isCancelled, !self.stopping else { return }
                    self.report("本地代理意外退出；Antigravity 仍在运行，请退出应用后重新启动。", busy: true)
                } else if let session = self.theme, !session.isAlive {
                    self.theme = nil
                    await Task.detached(priority: .userInitiated) { session.stop() }.value
                    guard !Task.isCancelled, !self.stopping else { return }
                    self.report("Codex 主题服务已退出。Antigravity 仍通过本地代理运行。", busy: true)
                }
            }
        }
    }

    private func cleanRuntime() async {
        let themeSession = theme
        let relaySession = relay
        theme = nil
        relay = nil
        guard themeSession != nil || relaySession != nil else { return }
        await Task.detached(priority: .userInitiated) {
            themeSession?.stop()
            relaySession?.stop()
        }.value
    }

    private func report(_ message: String, busy: Bool) {
        isRunning = busy
        onStatusChange?(message, busy)
    }

    static func validateApplicationForLaunch(at url: URL) throws {
        guard ApplicationLocator.isApplication(at: url) else {
            throw RuntimeFailure("所选应用缺少可执行文件，请选择完整的 Antigravity.app。")
        }
        try requireApplicationClosed(at: url)
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
            throw RuntimeFailure("Antigravity 已在运行。可以直接测试代理；启动前请先保存工作并正常退出 Antigravity，再通过本工具启动。")
        }
    }

    static func openApplication(at url: URL, port: Int, enableTheme: Bool = false) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = applicationArguments(at: url, port: port, enableTheme: enableTheme)
        configuration.environment = proxyEnvironment(port: port, base: ProcessInfo.processInfo.environment)
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

    static func applicationArguments(at url: URL, port: Int, enableTheme: Bool) -> [String] {
        var arguments = [
            "--proxy-server=http://127.0.0.1:\(port)",
            "--proxy-bypass-list=localhost;127.0.0.1;[::1]",
            "--disable-quic"
        ]
        if enableTheme, ThemeSession.supportsApplication(at: url) {
            arguments += ["--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0"]
        }
        return arguments
    }

    nonisolated static func proxyEnvironment(port: Int, base: [String: String]) -> [String: String] {
        var environment = base
        let httpProxy = "http://127.0.0.1:\(port)"
        let socksProxy = "socks5h://127.0.0.1:\(port)"
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            environment[key] = httpProxy
        }
        for key in ["ALL_PROXY", "all_proxy"] { environment[key] = socksProxy }
        for key in ["NO_PROXY", "no_proxy"] { environment[key] = "localhost,127.0.0.1,::1" }
        return environment
    }
}

struct RuntimeFailure: LocalizedError {
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

/// Owns one proxy core and its private runtime directory.
final class RelaySession: @unchecked Sendable {
    private let process = Process()
    private let stopLock = NSLock()
    private let directory: URL
    let port: Int
    private var lockDescriptor: Int32
    private var stopped = false
    private var routingRollbackFailed = false
    private let controllerSecret = UUID().uuidString
    private var controllerSocket: URL?
    private(set) var subscriptionNodeCount = 0
    private(set) var subscriptionNodes: [String] = []

    var isAlive: Bool { process.isRunning }
    var processIdentifier: pid_t { process.processIdentifier }
    var themeDirectory: URL { directory.appendingPathComponent("theme", isDirectory: true) }
    var canApplyRouting: Bool { !routingRollbackFailed && isAlive }
    private var configURL: URL { directory.appendingPathComponent("config.json") }

    private init(directory: URL, port: Int, lockDescriptor: Int32) {
        self.directory = directory
        self.port = port
        self.lockDescriptor = lockDescriptor
    }

    static func start(settings: ProxySettings, password: String, subscriptionURL: String = "",
                      relayURI: String = "",
                      progress: (@Sendable (String) -> Void)? = nil,
                      cancellation: RuntimeCancellation) throws -> RelaySession {
        try cancellation.check()
        // Validate here as well as in the UI so every caller fails before spawning a relay.
        try SettingsValidator.validate(settings)
        if settings.useSubscription { try SettingsValidator.validateSubscriptionURL(subscriptionURL) }
        if !settings.useSubscription && settings.useRelayURI {
            _ = try VlessRelayURI(relayURI, localPort: settings.localPort)
        }
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
        // A crashed launcher can leave a core process and its credential-bearing session
        // directory behind; holding the exclusive lock means any such core is an orphan.
        reconcileStaleSessions(progress: progress)
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
            // Fail fast on an occupied port instead of after a potentially slow download.
            try session.requireFreePort()
            // The subscription is downloaded by the app, not by the proxy core: on some
            // networks the core's in-process TLS download stalls while curl succeeds.
            var providerPath: String?
            if settings.useSubscription {
                let downloadProxy = settings.subscriptionUseManualProxy
                    ? SubscriptionDownloadProxy(settings: settings, password: password) : nil
                let snapshot = try SubscriptionFetcher.fetch(
                    url: subscriptionURL, proxy: downloadProxy,
                    checkCancellation: { try cancellation.check() },
                    into: directory, progress: { progress?($0) })
                providerPath = SubscriptionFetcher.subscriptionYAMLURL(in: directory).path
                session.controllerSocket = try Self.createControllerSocket(for: directory)
                progress?("已读取 \(snapshot.nodes.count) 个节点，正在启动本地代理…")
            }
            let configuration = try RelayConfiguration.make(settings: settings, password: password,
                subscriptionProviderPath: providerPath,
                controllerSocket: session.controllerSocket?.path ?? "",
                controllerSecret: session.controllerSecret,
                relayURI: relayURI)
            try session.writeConfigurationData(RelayConfiguration.serialize(configuration), to: session.configURL)
            // Re-check after the download: the port could have been taken while fetching.
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
            if settings.useSubscription {
                let groupName = settings.chainManualProxy ? "RELAY" : "UPSTREAM"
                try session.waitForSubscription(node: settings.subscriptionNode, groupName: groupName, cancellation: cancellation)
            }
            return session
        } catch {
            session.stop()
            throw error
        }
    }

    private func waitForSubscription(node: String, groupName: String = "UPSTREAM", cancellation: RuntimeCancellation) throws {
        let deadline = Date().addingTimeInterval(12)
        var healthCheckDeadline: Date?
        while Date() < deadline {
            try cancellation.check()
            guard isAlive else { throw RuntimeFailure("订阅代理启动失败，请检查内核版本和订阅格式。") }
            if let provider = try controllerRequest("/providers/proxies/SUBSCRIPTION", cancellation: cancellation),
               let list = provider["proxies"] as? [[String: Any]], !list.isEmpty {
                subscriptionNodes = list.compactMap { $0["name"] as? String }
                subscriptionNodeCount = subscriptionNodes.count
                if !node.isEmpty {
                    guard subscriptionNodes.contains(node) else {
                        throw RuntimeFailure("订阅中没有名为“\(node)”的节点。请在“节点”中重新选择，或点击“刷新节点”后再试。")
                    }
                    if let group = try controllerRequest("/proxies/\(groupName)", cancellation: cancellation),
                       group["now"] as? String == node {
                        return
                    }
                } else {
                    // Give the automatic selector a short head start. The exit probe
                    // still checks traffic when the health-check host is unavailable.
                    if healthCheckDeadline == nil { healthCheckDeadline = Date().addingTimeInterval(1.5) }
                    if list.contains(where: { hasSuccessfulHealthCheck($0) })
                        || healthCheckDeadline.map({ Date() >= $0 }) == true { return }
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard !subscriptionNodes.isEmpty else {
            throw RuntimeFailure("订阅未能加载：代理内核没有解析出节点。请确认订阅为 Clash/Mihomo YAML 且未过期。")
        }
        throw RuntimeFailure("无法确认指定的订阅节点，请刷新节点后重试。")
    }

    private func hasSuccessfulHealthCheck(_ proxy: [String: Any]) -> Bool {
        guard let history = proxy["history"] as? [[String: Any]] else { return false }
        return history.contains { ($0["delay"] as? Int ?? 0) > 0 }
    }

    private func controllerRequest(_ path: String, cancellation: RuntimeCancellation) throws -> [String: Any]? {
        guard let controllerSocket else { return nil }
        let responseURL = directory.appendingPathComponent("controller-response.json")
        let authURL = directory.appendingPathComponent("controller-auth.txt")
        defer {
            try? FileManager.default.removeItem(at: responseURL)
            try? FileManager.default.removeItem(at: authURL)
        }
        try AppPaths.writePrivate(Data("header = \"Authorization: Bearer \(controllerSecret)\"\n".utf8), to: authURL)
        try AppPaths.writePrivate(Data(), to: responseURL)
        let arguments = ["-q", "--silent", "--fail", "--max-time", "2", "--max-filesize", "2097152",
                         "--unix-socket", controllerSocket.path,
                         "--noproxy", "*", "--config", authURL.path,
                         "--output", responseURL.path, "http://localhost" + path]
        let result = try RuntimeCommand.run(executable: "/usr/bin/curl", arguments: arguments,
            timeout: 2.5, cancellation: cancellation, captureOutput: false, directory: directory)
        guard result.status == 0 else { return nil }
        let data = try Data(contentsOf: responseURL)
        if data.isEmpty { return [:] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func prepareRouting(_ routing: RoutingPolicy, cancellation: RuntimeCancellation) throws -> RelayRoutingUpdate {
        try cancellation.check()
        guard isAlive else { throw RuntimeFailure("本地代理已退出，分流规则未更新。") }
        let currentData = try Data(contentsOf: configURL)
        guard var candidate = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
            throw RuntimeFailure("无法读取当前会话的配置，分流规则未更新。")
        }
        candidate["rules"] = routing.rules
        let data = try RelayConfiguration.serialize(candidate)
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

    /// Stops proxy cores orphaned by a crash/force-quit and removes their session
    /// directories, so a stale relay can neither hold the local port nor keep credentials.
    private static func reconcileStaleSessions(progress: (@Sendable (String) -> Void)?) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.runtimeDirectory, includingPropertiesForKeys: nil) else { return }
        let directories = entries.filter {
            UUID(uuidString: $0.lastPathComponent) != nil && isPrivateDirectory($0)
        }
        guard !directories.isEmpty else { return }

        // A relay must both run our binary and have a launcher session as its
        // working directory. Other users of the same executable are left alone.
        let paths = Set(directories.map { resolvedPath($0.path) })
        let processes = runningCoreProcesses(in: paths)
        for process in processes where process.isRunning { kill(process.pid, SIGTERM) }
        waitForOrphans(processes, timeout: 2)
        for process in processes where process.isRunning { kill(process.pid, SIGKILL) }
        waitForOrphans(processes, timeout: 1)

        let activePaths = Set(processes.filter(\.isRunning).map(\.directory))
        var removedAny = false
        for directory in directories where !activePaths.contains(resolvedPath(directory.path)) {
            removeControllerSocket(for: directory)
            if (try? FileManager.default.removeItem(at: directory)) != nil { removedAny = true }
        }
        if processes.contains(where: { !$0.isRunning }) {
            progress?("已清理上次异常退出残留的本地代理。")
        } else if removedAny {
            progress?("已清理上次异常退出残留的临时配置。")
        }
    }

    /// Compares real paths: `/tmp/x` and `/private/tmp/x` are the same file, and
    /// `proc_pidpath` reports the resolved form.
    static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func waitForOrphans(_ processes: [OrphanedRelay], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, processes.contains(where: \.isRunning) {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func runningCoreProcesses(in directories: Set<String>) -> [OrphanedRelay] {
        let expected = resolvedPath(AppPaths.mihomoExecutable.path)
        let needed = proc_listpids(1 /* PROC_ALL_PIDS */, 0, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let written = proc_listpids(1, 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        let count = min(pids.count, Int(written) / MemoryLayout<pid_t>.size)
        var matches: [OrphanedRelay] = []
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0, pid != getpid() else { continue }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  resolvedPath(String(cString: buffer)) == expected,
                  let process = OrphanedRelay(pid: pid), directories.contains(process.directory) else { continue }
            matches.append(process)
        }
        return matches
    }

    private struct OrphanedRelay {
        let pid: pid_t
        let directory: String
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        init?(pid: pid_t) {
            guard let info = Self.processInfo(pid) else { return nil }
            var paths = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, size) == size else { return nil }
            let cwd = withUnsafeBytes(of: paths.pvi_cdir.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard !cwd.isEmpty else { return nil }
            self.pid = pid
            directory = RelaySession.resolvedPath(cwd)
            startSeconds = info.pbi_start_tvsec
            startMicroseconds = info.pbi_start_tvusec
        }

        var isRunning: Bool {
            guard let info = Self.processInfo(pid) else { return false }
            return info.pbi_start_tvsec == startSeconds && info.pbi_start_tvusec == startMicroseconds
        }

        private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == getuid() else { return nil }
            return info
        }
    }

    /// Darwin's Unix socket address is limited to 104 bytes, so it may not fit
    /// under Application Support. Mihomo resolves relative socket paths there too.
    private static func controllerSocketDirectory(for session: URL) -> URL {
        URL(fileURLWithPath: "/tmp/antigravity-isp-" + session.lastPathComponent, isDirectory: true)
    }

    private static func createControllerSocket(for session: URL) throws -> URL {
        let directory = controllerSocketDirectory(for: session)
        guard mkdir(directory.path, 0o700) == 0 else {
            throw RuntimeFailure("无法创建订阅代理的私有控制目录。")
        }
        return directory.appendingPathComponent("controller.sock")
    }

    private static func removeControllerSocket(for session: URL) {
        let directory = controllerSocketDirectory(for: session)
        guard isPrivateDirectory(directory) else { return }
        let socket = directory.appendingPathComponent("controller.sock")
        var info = stat()
        if lstat(socket.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK {
            unlink(socket.path)
        }
        rmdir(directory.path)
    }

    private static func isPrivateDirectory(_ directory: URL) -> Bool {
        var info = stat()
        return lstat(directory.path, &info) == 0 && info.st_uid == getuid()
            && (info.st_mode & S_IFMT) == S_IFDIR && (info.st_mode & 0o077) == 0
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
        guard isAlive else { throw RuntimeFailure("本地代理已退出。") }
        // Probe every echo endpoint concurrently: the fastest usable answer wins, and a
        // broken node fails in a few seconds instead of waiting out each endpoint in turn.
        let probeCancellation = RuntimeCancellation()
        let lock = NSLock()
        var detectedIP: String?
        let firstAnswer = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        defer {
            probeCancellation.cancel()
            _ = group.wait(timeout: .now() + 2)
        }
        for endpoint in RoutingPolicy.exitIPCheckEndpoints {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { group.leave() }
                guard let self,
                      let value = try? self.probeExitIP(endpoint: endpoint, cancellation: probeCancellation),
                      let canonical = canonicalIP(value) else { return }
                lock.lock()
                let isFirst = detectedIP == nil
                if isFirst { detectedIP = canonical }
                lock.unlock()
                if isFirst { firstAnswer.signal() }
            }
        }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            try cancellation.check()
            if firstAnswer.wait(timeout: .now() + 0.1) == .success || group.wait(timeout: .now()) == .success {
                break
            }
        }
        try cancellation.check()
        lock.lock()
        let resolvedIP = detectedIP
        lock.unlock()
        guard let detectedIP = resolvedIP else {
            throw RuntimeFailure("代理出口检查失败：所有出口检测地址都无法通过代理访问。请核对节点、订阅和网络连通性。")
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

    private func probeExitIP(endpoint: String, cancellation: RuntimeCancellation) throws -> String {
        guard isAlive else { throw RuntimeFailure("本地代理已退出。") }
        let result = try RuntimeCommand.run(
            executable: "/usr/bin/curl",
            // Each probe hostname is pinned to UPSTREAM. A redirected hostname may be DIRECT.
            arguments: ["-q", "--silent", "--show-error", "--fail",
                        "--connect-timeout", "4", "--max-time", "6",
                        "--max-filesize", "16384",
                        "--proxy", "http://127.0.0.1:\(port)", "--noproxy", "", endpoint],
            timeout: 7, cancellation: cancellation
        )
        guard result.status == 0 else { throw RuntimeFailure("出口检测地址不可用。") }
        let value = exitIPValue(from: result.output, endpoint: endpoint)
        guard canonicalIP(value) != nil else { throw RuntimeFailure("出口检测结果无效。") }
        return value
    }

    private func exitIPValue(from output: String, endpoint: String) -> String {
        if endpoint.contains("cloudflare") {
            return output.split(separator: "\n").first(where: { $0.hasPrefix("ip=") })
                .map { String($0.dropFirst(3)) } ?? ""
        }
        if endpoint.contains("myip.com") {
            guard let data = output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ip = object["ip"] as? String else { return "" }
            return ip
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if controllerSocket != nil { Self.removeControllerSocket(for: directory) }
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

enum RuntimeCommand {
    static func run(executable: String, arguments: [String], timeout: TimeInterval,
                    cancellation: RuntimeCancellation, captureOutput: Bool = true,
                    directory: URL? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = captureOutput ? Pipe() : nil
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
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
