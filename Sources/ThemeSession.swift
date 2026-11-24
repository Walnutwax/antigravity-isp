import Darwin
import Foundation

/// Owns the bundled Codex Theme daemon for one proxied Antigravity desktop process.
final class ThemeSession: @unchecked Sendable {
    struct Configuration: Sendable {
        let executable: URL
        let daemon: URL
    }

    private let process = Process()
    private let directory: URL
    private let stopLock = NSLock()
    private var stopped = false

    var isAlive: Bool { process.isRunning }

    private init(directory: URL) {
        self.directory = directory
    }

    static func supportsApplication(at url: URL) -> Bool {
        Bundle(url: url)?.bundleIdentifier == "com.google.antigravity"
    }

    static func prepare(nodePath: String, cancellation: RuntimeCancellation,
                        resourceDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("CodexTheme")) throws -> Configuration {
        try cancellation.check()
        guard let daemon = resourceDirectory?.appendingPathComponent("core/daemon.mjs"),
              FileManager.default.isReadableFile(atPath: daemon.path),
              (try? daemon.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw RuntimeFailure("应用包缺少主题资源。")
        }

        let explicitPath = (nodePath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let candidates = explicitPath.isEmpty ? nodeCandidates() : [explicitPath]
        for candidate in candidates where candidate.hasPrefix("/") {
            try cancellation.check()
            let executable = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            guard isTrustedExecutable(executable) else { continue }
            let version = try? RuntimeCommand.run(executable: executable.path, arguments: ["--version"],
                                                  timeout: 2, cancellation: cancellation)
            try cancellation.check()
            if let version, version.status == 0, supportsNodeVersion(version.output) {
                return Configuration(executable: executable, daemon: daemon)
            }
        }
        throw RuntimeFailure(explicitPath.isEmpty
            ? "未找到 Node.js 22.13 或更高版本，请在设置中选择 Node.js 可执行文件。"
            : "指定的 Node.js 不可用，请选择可执行的 22.13 或更高版本。")
    }

    private static func nodeCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let nvm = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let versions = (try? FileManager.default.contentsOfDirectory(
            at: nvm, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return [
            "/opt/homebrew/bin/node", "/usr/local/bin/node", "/opt/local/bin/node",
            "/opt/homebrew/opt/node@24/bin/node", "/opt/homebrew/opt/node@22/bin/node",
            "/usr/local/opt/node@24/bin/node", "/usr/local/opt/node@22/bin/node"
        ] + versions
            .filter { supportsNodeVersion($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/node").path }
    }

    private static func isTrustedExecutable(_ executable: URL) -> Bool {
        var metadata = stat()
        return lstat(executable.path, &metadata) == 0
            && (metadata.st_mode & S_IFMT) == S_IFREG
            && (metadata.st_uid == 0 || metadata.st_uid == getuid())
            && (metadata.st_mode & 0o022) == 0
            && FileManager.default.isExecutableFile(atPath: executable.path)
    }

    static func supportsNodeVersion(_ raw: String) -> Bool {
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.hasPrefix("v") else { return false }
        let fields = version.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let major = Int(fields[0]), let minor = Int(fields[1]) else { return false }
        return major > 22 || (major == 22 && minor >= 13)
    }

    static func start(configuration: Configuration, discovery: ThemeEndpointDiscovery, applicationPID: pid_t,
                      relay: RelaySession, cancellation: RuntimeCancellation) throws -> ThemeSession {
        try cancellation.check()
        let endpoint = try discovery.wait(applicationPID: applicationPID, cancellation: cancellation) {
            try requireRunning(applicationPID: applicationPID, relay: relay)
        }
        let directory = relay.themeDirectory
        guard mkdir(directory.path, 0o700) == 0 else {
            throw RuntimeFailure("无法创建主题会话的私有目录。")
        }
        let session = ThemeSession(directory: directory)
        do {
            let portFile = directory.appendingPathComponent("DevToolsActivePort")
            try AppPaths.writePrivate(Data(endpoint.utf8), to: portFile)
            try cancellation.check()
            try requireRunning(applicationPID: applicationPID, relay: relay)

            let process = session.process
            // Node loads the watchdog before the daemon. It exits if the launcher
            // is force-quit or if the app/proxy disappears between Swift monitor ticks.
            let watchdog = """
                const parent = \(getpid());
                const children = [\(applicationPID), \(relay.processIdentifier)];
                const check = () => {
                  if (process.ppid !== parent) process.exit(0);
                  try { for (const pid of children) process.kill(pid, 0); }
                  catch { process.exit(0); }
                };
                check();
                setInterval(check, 250).unref();
                """
            process.executableURL = configuration.executable
            process.arguments = ["--import", "data:text/javascript;base64," + Data(watchdog.utf8).base64EncodedString(),
                                 configuration.daemon.path, "--channel", "stable", "--port-file", portFile.path]
            process.currentDirectoryURL = directory
            process.environment = LauncherController.proxyEnvironment(port: relay.port, base: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "TMPDIR": directory.path
            ])
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            try cancellation.check()
            try requireRunning(applicationPID: applicationPID, relay: relay)
            guard process.isRunning else { throw RuntimeFailure("主题服务启动后立即退出。") }
            return session
        } catch {
            session.stop()
            throw error
        }
    }

    private static func requireRunning(applicationPID: pid_t, relay: RelaySession) throws {
        guard applicationPID > 0, kill(applicationPID, 0) == 0 else { throw RuntimeFailure("Antigravity 已退出。") }
        guard relay.isAlive else { throw RuntimeFailure("本地代理已退出。") }
    }

    func stop() {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !stopped else { return }
        stopped = true
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }
}

/// Captures the port file just before Launch Services starts Antigravity. The file
/// must change after that point, and only the launched process can own the listener.
struct ThemeEndpointDiscovery: Sendable {
    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let seconds: Int
        let nanoseconds: Int

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            seconds = metadata.st_mtimespec.tv_sec
            nanoseconds = metadata.st_mtimespec.tv_nsec
        }

        var modifiedAt: Date {
            Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
        }
    }

    private static var officialPortFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/DevToolsActivePort")
    }

    private let portFile: URL
    private let beforeLaunch: Stamp?
    private let requestedAt: Date

    init(portFile: URL? = nil) {
        let url = portFile ?? Self.officialPortFile
        self.portFile = url
        var metadata = stat()
        beforeLaunch = lstat(url.path, &metadata) == 0 ? Stamp(metadata) : nil
        requestedAt = Date()
    }

    func wait(applicationPID: pid_t, cancellation: RuntimeCancellation,
              checkRunning: () throws -> Void) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            try cancellation.check()
            try checkRunning()
            if let endpoint = try verifiedEndpoint(applicationPID: applicationPID, cancellation: cancellation) {
                return endpoint
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw RuntimeFailure("未找到此 Antigravity 进程的本机调试端口。")
    }

    func verifiedEndpoint(applicationPID: pid_t, cancellation: RuntimeCancellation) throws -> String? {
        guard applicationPID > 0 else { return nil }
        let descriptor = open(portFile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_uid == getuid(),
              (metadata.st_mode & 0o022) == 0, (1...512).contains(metadata.st_size) else { return nil }
        let stamp = Stamp(metadata)
        guard stamp != beforeLaunch, stamp.modifiedAt >= requestedAt else { return nil }
        var bytes = [UInt8](repeating: 0, count: 513)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == metadata.st_size,
              let raw = String(bytes: bytes.prefix(count), encoding: .utf8) else { return nil }
        let lines = raw.split(whereSeparator: \.isNewline)
        let browserPrefix = "/devtools/browser/"
        guard lines.count == 2, let port = Int(lines[0]), (1...65535).contains(port), lines[0] == Substring(String(port)),
              lines[1].hasPrefix(browserPrefix),
              UUID(uuidString: String(lines[1].dropFirst(browserPrefix.count))) != nil else { return nil }

        let result = try RuntimeCommand.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-a", "-p", String(applicationPID), "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pn"],
            timeout: 2, cancellation: cancellation
        )
        let fields = result.output.split(separator: "\n")
        let listeners = fields.filter { $0.hasPrefix("n") }
        let ipv4 = "n127.0.0.1:\(port)"
        let ipv6 = "n[::1]:\(port)"
        guard result.status == 0, fields.first == Substring("p\(applicationPID)"),
              listeners.contains(Substring(ipv4)), listeners.allSatisfy({ $0 == ipv4 || $0 == ipv6 }) else {
            return nil
        }
        return "\(port)\n\(lines[1])\n"
    }
}
