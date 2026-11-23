import CryptoKit
import Foundation

/// One node parsed from a Clash/Mihomo subscription.
struct SubscriptionNode: Codable, Equatable, Sendable {
    var name: String
    var type: String
}

/// A downloaded subscription: the node catalog plus the provider usage header, if present.
struct SubscriptionSnapshot: Equatable, Sendable {
    let nodes: [SubscriptionNode]
    let userInfo: String
}

/// The last successfully read node catalog. Persisted so the picker is populated at launch.
struct SubscriptionCatalog: Codable, Equatable, Sendable {
    /// A hash of the subscription URL: the catalog only needs to notice address changes,
    /// and the URL itself is a bearer token that stays in the Keychain.
    var urlFingerprint: String
    var nodes: [SubscriptionNode]
    var fetchedAt: Date

    static func fingerprint(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Metadata for the on-disk subscription cache (the YAML body lives in a private file).
struct SubscriptionCacheMetadata: Codable, Equatable, Sendable {
    var urlFingerprint: String
    var fetchedAt: Date
    var userInfo: String
}

/// Reuses a recently downloaded subscription so repeated connection tests skip the
/// network entirely, and falls back to a stale copy when the network is unreachable.
enum SubscriptionCache {
    static let maximumAge: TimeInterval = 10 * 60

    static func load(for url: String, maximumAge: TimeInterval?,
                     now: Date = Date()) -> (yaml: Data, metadata: SubscriptionCacheMetadata)? {
        guard let metadataData = try? Data(contentsOf: AppPaths.subscriptionCacheMetadataFile),
              let metadata = try? JSONDecoder().decode(SubscriptionCacheMetadata.self, from: metadataData),
              metadata.urlFingerprint == SubscriptionCatalog.fingerprint(url),
              let yaml = try? Data(contentsOf: AppPaths.subscriptionCacheFile), !yaml.isEmpty else {
            return nil
        }
        if let maximumAge, now.timeIntervalSince(metadata.fetchedAt) > maximumAge { return nil }
        let text = String(decoding: yaml, as: UTF8.self)
        guard SubscriptionParser.hasNodeEntries(in: text) else { return nil }
        return (yaml, metadata)
    }

    static func store(yaml: Data, for url: String, userInfo: String, now: Date = Date()) {
        // A cache write must never turn a successful test/launch into a failure.
        let metadata = SubscriptionCacheMetadata(urlFingerprint: SubscriptionCatalog.fingerprint(url),
                                                 fetchedAt: now, userInfo: userInfo)
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? AppPaths.writePrivate(yaml, to: AppPaths.subscriptionCacheFile)
        try? AppPaths.writePrivate(data, to: AppPaths.subscriptionCacheMetadataFile)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: AppPaths.subscriptionCacheFile)
        try? FileManager.default.removeItem(at: AppPaths.subscriptionCacheMetadataFile)
    }

    static func ageDescription(_ fetchedAt: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(fetchedAt))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        return String(format: "%.1f 小时前", seconds / 3600)
    }
}

/// Optional manual proxy used only for downloading the subscription itself.
struct SubscriptionDownloadProxy: Equatable, Sendable {
    let proxyType: String
    let server: String
    let port: Int
    let username: String
    let password: String

    init(settings: ProxySettings, password: String) {
        proxyType = settings.proxyType
        server = settings.server
        port = settings.port
        username = settings.username
        self.password = password
    }

}

/// Serializes sensitive curl request values into a private config file so the
/// subscription URL (a bearer token) and proxy credentials never appear in the
/// process argument list, where other local processes could read them via `ps`.
struct SubscriptionCurlRequest: Equatable {
    let configText: String

    init(url: String, proxy: SubscriptionDownloadProxy?) {
        var lines = ["url = \"\(Self.escape(url))\""]
        if let proxy {
            let scheme: String
            switch proxy.proxyType {
            case "https": scheme = "https"
            case "socks5": scheme = "socks5h"
            default: scheme = "http"
            }
            lines.append("proxy = \"\(Self.escape("\(scheme)://\(proxy.server):\(proxy.port)"))\"")
            if !proxy.username.isEmpty {
                lines.append("proxy-user = \"\(Self.escape("\(proxy.username):\(proxy.password)"))\"")
            }
        }
        configText = lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

/// Parses the `proxies:` list out of a Clash/Mihomo YAML subscription.
///
/// This is deliberately a narrow, dependency-free reader for the one shape a
/// subscription needs here: a top-level `proxies:` sequence whose entries expose
/// `name` and `type`. It never tries to interpret proxy credentials or options;
/// the proxy core does the authoritative parsing of the downloaded file.
enum SubscriptionParser {
    static func nodes(in text: String) -> [SubscriptionNode] {
        guard let yaml = normalize(text) else { return [] }
        let lines = yaml.components(separatedBy: .newlines)
        guard let proxiesLine = lines.firstIndex(where: { isKeyLine($0, key: "proxies") }) else { return [] }
        // `proxies: [{name: a, type: ss}, ...]` (single or multi line flow sequence).
        if let colon = lines[proxiesLine].firstIndex(of: ":") {
            var remainder = String(lines[proxiesLine][lines[proxiesLine].index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if remainder.hasPrefix("[") {
                var cursor = proxiesLine + 1
                while !flowSequenceComplete(stripFlowComments(remainder)), cursor < lines.count {
                    remainder += "\n" + lines[cursor]
                    cursor += 1
                }
                return flowSequenceNodes(remainder)
            }
        }
        var nodes: [SubscriptionNode] = []
        var seen = Set<String>()
        var entry: [String] = []

        func finishEntry() {
            guard let node = node(from: entry) else { return }
            guard !node.name.isEmpty, !seen.contains(node.name) else { return }
            seen.insert(node.name)
            nodes.append(node)
        }

        var index = proxiesLine + 1
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            let indent = leadingSpaceCount(raw)
            if indent == 0, !line.hasPrefix("-") {
                // A new top-level key closes the proxies sequence.
                break
            }
            if line.hasPrefix("-") {
                finishEntry()
                entry = [raw]
            } else if !entry.isEmpty {
                entry.append(raw)
            }
        }
        finishEntry()
        return nodes
    }

    /// True when the `proxies:` block has at least one entry, even if this narrow parser
    /// could not name it (anchors, exotic flow styles). The proxy core remains authoritative.
    static func hasNodeEntries(in text: String) -> Bool {
        guard let yaml = normalize(text) else { return false }
        let lines = yaml.components(separatedBy: .newlines)
        guard let proxiesLine = lines.firstIndex(where: { isKeyLine($0, key: "proxies") }) else { return false }
        if let colon = lines[proxiesLine].firstIndex(of: ":") {
            let rest = stripComment(String(lines[proxiesLine][lines[proxiesLine].index(after: colon)...]))
                .trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                return rest != "[]" && rest != "[ ]" && rest.lowercased() != "null" && rest != "~"
            }
        }
        for raw in lines[(proxiesLine + 1)...] {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if leadingSpaceCount(raw) == 0, !line.hasPrefix("-") { return false }
            return true
        }
        return false
    }

    private static func flowSequenceComplete(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        var opened = false
        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let active = quote { if character == active { quote = nil }; continue }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "[" || character == "{" { depth += 1; opened = true }
            else if character == "]" || character == "}" { depth -= 1 }
        }
        return opened && depth <= 0
    }

    private static func flowSequenceNodes(_ rawText: String) -> [SubscriptionNode] {
        let text = stripFlowComments(rawText)
        guard let start = text.firstIndex(of: "[") else { return [] }
        var depth = 0
        var quote: Character?
        var escaped = false
        var end: String.Index?
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if let active = quote { if character == active { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == "[" || character == "{" { depth += 1 }
            else if character == "]" || character == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
            index = text.index(after: index)
        }
        guard let end else { return [] }
        let body = String(text[text.index(after: start)..<end])
        var nodes: [SubscriptionNode] = []
        var seen = Set<String>()
        for item in splitTopLevel(body) {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") else { continue }
            let pairs = flowPairs(trimmed)
            guard let name = pairs["name"] else { continue }
            let node = SubscriptionNode(name: scalar(name), type: scalar(pairs["type"] ?? ""))
            guard !node.name.isEmpty, !seen.contains(node.name) else { continue }
            seen.insert(node.name)
            nodes.append(node)
        }
        return nodes
    }

    /// Drops YAML comments inside a flow collection while preserving `#` in quoted scalars.
    private static func stripFlowComments(_ text: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        var previous: Character = "\n"
        var skipping = false
        for character in text {
            if skipping {
                if character == "\n" { skipping = false; result.append(character); previous = character }
                continue
            }
            if escaped {
                result.append(character)
                escaped = false
                previous = character
                continue
            }
            if character == "\\" {
                result.append(character)
                escaped = true
                previous = character
                continue
            }
            if let active = quote {
                result.append(character)
                if character == active { quote = nil }
                previous = character
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                result.append(character)
                previous = character
                continue
            }
            if character == "#", previous == " " || previous == "\t" || previous == "\n" || previous == "\r" {
                skipping = true
                continue
            }
            result.append(character)
            previous = character
        }
        return result
    }

    /// Splits a flow collection's contents on top-level commas.
    private static func splitTopLevel(_ body: String) -> [String] {
        var items: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in body {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; current.append(character); continue }
            if character == "{" || character == "[" { depth += 1; current.append(character); continue }
            if character == "}" || character == "]" { depth -= 1; current.append(character); continue }
            if character == ",", depth == 0 { items.append(current); current = ""; continue }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(current) }
        return items
    }

    /// Returns YAML text, decoding a Base64-wrapped YAML document when needed.
    static func normalize(_ text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        if hasProxiesKey(cleaned) { return cleaned }
        let compact = cleaned.components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard compact.count >= 24,
              let data = Data(base64Encoded: compact, options: .ignoreUnknownCharacters),
              var decoded = String(data: data, encoding: .utf8) else { return nil }
        decoded = decoded.replacingOccurrences(of: "\u{FEFF}", with: "")
        guard hasProxiesKey(decoded) else { return nil }
        return decoded
    }

    private static func hasProxiesKey(_ text: String) -> Bool {
        text.range(of: #"(?m)^proxies[ \t]*:"#, options: .regularExpression) != nil
    }

    private static func node(from entry: [String]) -> SubscriptionNode? {
        guard let firstRaw = entry.first else { return nil }
        let first = firstRaw.trimmingCharacters(in: .whitespaces)
        var inline = String(first.dropFirst()).trimmingCharacters(in: .whitespaces)
        // Flow style: `- {name: "x", type: ss, ...}`.
        if inline.hasPrefix("{") {
            let joined = ([inline] + entry.dropFirst()).joined(separator: " ")
            let pairs = flowPairs(joined)
            guard let name = pairs["name"] else { return nil }
            return SubscriptionNode(name: scalar(name), type: scalar(pairs["type"] ?? ""))
        }
        var name: String?
        var type = ""
        var keyIndent: Int?
        for (position, raw) in entry.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if position == 0 { inline = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if position > 0 {
                let lineIndent = leadingSpaceCount(raw)
                if let expected = keyIndent {
                    guard lineIndent == expected else { continue }
                } else {
                    // The first key line inside the entry fixes the mapping's key indent.
                    keyIndent = lineIndent
                }
            }
            guard let pair = keyValue(position == 0 ? inline : trimmed) else { continue }
            switch pair.key {
            case "name": name = scalar(pair.value)
            case "type": type = scalar(pair.value)
            default: break
            }
        }
        guard let name else { return nil }
        return SubscriptionNode(name: name, type: type)
    }

    private static func isKeyLine(_ line: String, key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix(" ") && !line.hasPrefix("\t"), !trimmed.hasPrefix("-") else { return false }
        return keyValue(trimmed)?.key == key
    }

    private static func keyValue(_ text: String) -> (key: String, value: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        let value = stripComment(String(text[text.index(after: colon)...]))
            .trimmingCharacters(in: .whitespaces)
        return (key.lowercased(), value)
    }

    /// Removes an unquoted ` # comment` suffix while preserving `#` inside quoted names.
    /// Only a quote at the start of the scalar starts quoted mode, so a plain name such
    /// as `It's a node # note` still has its comment stripped.
    private static func stripComment(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return raw }
        if first == "\"" || first == "'" {
            let quote = first
            var escaped = false
            var index = trimmed.index(after: trimmed.startIndex)
            while index < trimmed.endIndex {
                let character = trimmed[index]
                if escaped {
                    escaped = false
                } else if character == "\\", quote == "\"" {
                    escaped = true
                } else if character == quote {
                    if quote == "'", trimmed.index(after: index) < trimmed.endIndex,
                       trimmed[trimmed.index(after: index)] == "'" {
                        index = trimmed.index(after: index)
                    } else {
                        return String(trimmed[...index])
                    }
                }
                index = trimmed.index(after: index)
            }
            return trimmed
        }
        for marker in [" #", "\t#"] {
            if let range = raw.range(of: marker) { return String(raw[..<range.lowerBound]) }
        }
        return raw
    }

    private static func flowPairs(_ text: String) -> [String: String] {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("{") { body.removeFirst() }
        if body.hasSuffix("}") { body.removeLast() }
        var pairs: [String: String] = [:]
        var current = ""
        var quote: Character?
        var escaped = false
        var depth = 0
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "{" || character == "[" {
                depth += 1
                current.append(character)
            } else if character == "}" || character == "]" {
                depth -= 1
                current.append(character)
            } else if character == ",", depth == 0 {
                if let pair = keyValue(current) { pairs[pair.key] = pair.value }
                current = ""
            } else {
                current.append(character)
            }
        }
        if let pair = keyValue(current) { pairs[pair.key] = pair.value }
        return pairs
    }

    private static func scalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            let inner = value.dropFirst().dropLast()
            var result = ""
            var escaped = false
            for character in inner {
                if escaped {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    default: result.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    result.append(character)
                }
            }
            if escaped { result.append("\\") }
            return result
        }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private static func leadingSpaceCount(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}

/// Formats the `subscription-userinfo` response header for the status line.
enum SubscriptionUsage {
    static func summary(fromUserInfo header: String, now: Date = Date()) -> String {
        var fields: [String: Int64] = [:]
        for part in header.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            let raw = pair[1].trimmingCharacters(in: .whitespaces)
            if let value = Int64(raw) { fields[key] = value }
        }
        guard let total = fields["total"], total > 0 else { return "" }
        let used = max(0, fields["upload"] ?? 0) + max(0, fields["download"] ?? 0)
        var summary = "已用 \(bytes(used)) / \(bytes(total))"
        if let expire = fields["expire"], expire > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(expire))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            summary += date < now ? " · 已过期" : " · 有效期至 \(formatter.string(from: date))"
        }
        return summary
    }

    private static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value)
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        return unit == 0 ? "\(value) B" : String(format: "%.1f %@", size, units[unit])
    }
}

/// Downloads a subscription with curl and writes the parsed YAML into a private directory.
///
/// Using curl (instead of the proxy core's built-in provider downloader) keeps the
/// subscription fetch independent of the local relay: it can run before the relay
/// exists, honours the optional manual download proxy, retries a flaky direct route,
/// and its TLS/HTTP behavior matches what the rest of the app already uses for probes.
enum SubscriptionFetcher {
    static let maximumBodyBytes = 16 * 1024 * 1024
    static let attempts = 3
    static let rounds = 2

    static func fetch(url: String, proxy: SubscriptionDownloadProxy?, checkCancellation: @escaping () throws -> Void,
                      into directory: URL, useCache: Bool = true,
                      progress: (String) -> Void) throws -> SubscriptionSnapshot {
        try SettingsValidator.validateSubscriptionURL(url)
        if let proxy {
            guard !proxy.server.isEmpty, (1...65535).contains(proxy.port),
                  !proxy.server.contains(where: { $0.isWhitespace }),
                  !proxy.username.contains(":"), !proxy.username.contains(where: { $0.isNewline }),
                  !proxy.password.contains(where: { $0.isNewline }) else {
                throw UserFacingError("下载订阅用的手动代理信息无效，请检查地址、端口、用户名和密码。")
            }
        }
        try AppPaths.createPrivateDirectory(directory)
        if useCache, let cached = SubscriptionCache.load(for: url, maximumAge: SubscriptionCache.maximumAge) {
            progress("使用 \(SubscriptionCache.ageDescription(cached.metadata.fetchedAt))获取的订阅缓存，跳过下载…")
            try AppPaths.writePrivate(cached.yaml, to: subscriptionYAMLURL(in: directory))
            let nodes = SubscriptionParser.nodes(in: String(decoding: cached.yaml, as: UTF8.self))
            return SubscriptionSnapshot(nodes: nodes, userInfo: cached.metadata.userInfo)
        }
        var lastFailure = ""
        var contentFailure: String?
        for round in 1...rounds {
            try checkCancellation()
            progress(round == 1
                ? "正在获取订阅（\(attempts) 路并发）…"
                : "正在重新获取订阅（第 \(round)/\(rounds) 轮）…")
            let outcome = try fetchRound(url: url, proxy: proxy, directory: directory,
                                         ipv4Only: true, checkCancellation: checkCancellation)
            try checkCancellation()
            switch outcome {
            case .success(let fetched):
                try AppPaths.writePrivate(fetched.yaml, to: subscriptionYAMLURL(in: directory))
                SubscriptionCache.store(yaml: fetched.yaml, for: url, userInfo: fetched.userInfo)
                return fetched.snapshot
            case .contentFailure(let message):
                contentFailure = message
            case .transportFailure(let message):
                lastFailure = message
            }
            if contentFailure != nil { break }
            if round < rounds { Thread.sleep(forTimeInterval: 0.5) }
        }
        if useCache, let stale = SubscriptionCache.load(for: url, maximumAge: nil) {
            progress("订阅获取失败，改用 \(SubscriptionCache.ageDescription(stale.metadata.fetchedAt))的缓存…")
            try AppPaths.writePrivate(stale.yaml, to: subscriptionYAMLURL(in: directory))
            let nodes = SubscriptionParser.nodes(in: String(decoding: stale.yaml, as: UTF8.self))
            return SubscriptionSnapshot(nodes: nodes, userInfo: stale.metadata.userInfo)
        }
        if let contentFailure {
            throw UserFacingError("无法使用该订阅：\(contentFailure)。请确认订阅地址返回的是 Clash/Mihomo YAML（可含 Base64 编码）。")
        }
        let detail = lastFailure.trimmingCharacters(in: CharacterSet(charactersIn: "。. "))
        throw UserFacingError(proxy == nil
            ? "无法获取订阅：\(detail)。本机直连订阅地址失败时，可勾选“通过手动代理下载订阅（本机直连失败时）”并填写一个可用代理。"
            : "无法通过手动代理获取订阅：\(detail)。请核对该代理是否可用。")
    }

    private struct FetchedSubscription {
        let snapshot: SubscriptionSnapshot
        let yaml: Data
        let userInfo: String
    }

    private enum RoundOutcome {
        case success(FetchedSubscription)
        case contentFailure(String)
        case transportFailure(String)
    }

    /// Races several curl workers for the same subscription. On flaky networks a single
    /// TLS connection often stalls while a sibling succeeds, so this both improves the
    /// import success rate and shortens the worst case to roughly one round of timeouts.
    private static func fetchRound(url: String, proxy: SubscriptionDownloadProxy?, directory: URL,
                                   ipv4Only: Bool,
                                   checkCancellation: @escaping () throws -> Void) throws -> RoundOutcome {
        let roundCancellation = FetchCancellation()
        let lock = NSLock()
        var winner: FetchedSubscription?
        var contentFailure: String?
        var transportFailure = ""
        let semaphore = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for worker in 0..<attempts {
            let bodyURL = directory.appendingPathComponent("subscription-download-\(worker).tmp")
            let headerURL = directory.appendingPathComponent("subscription-header-\(worker).tmp")
            try? FileManager.default.removeItem(at: bodyURL)
            try? FileManager.default.removeItem(at: headerURL)
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    group.leave()
                    try? FileManager.default.removeItem(at: bodyURL)
                    try? FileManager.default.removeItem(at: headerURL)
                }
                let outcome: RoundOutcome
                do {
                    let result = try runCurl(url: url, proxy: proxy, body: bodyURL, headers: headerURL,
                                             ipv4Only: ipv4Only,
                                             checkCancellation: {
                                                 try checkCancellation()
                                                 try roundCancellation.check()
                                             })
                    if result.status == 0,
                       let data = try? Data(contentsOf: bodyURL), !data.isEmpty,
                       data.count <= maximumBodyBytes {
                        let text = String(decoding: data, as: UTF8.self)
                        if let snapshot = parse(data: data),
                           !snapshot.nodes.isEmpty || SubscriptionParser.hasNodeEntries(in: text) {
                            let yaml = SubscriptionParser.normalize(text) ?? text
                            let finalData = Data(yaml.utf8)
                            if finalData.count <= maximumBodyBytes {
                                outcome = .success(FetchedSubscription(
                                    snapshot: snapshot, yaml: finalData,
                                    userInfo: headerValue("subscription-userinfo", in: headerURL) ?? ""))
                            } else {
                                outcome = .contentFailure("订阅内容超过 16 MB，已停止处理")
                            }
                        } else {
                            outcome = .contentFailure("订阅内容不是 Clash/Mihomo YAML，或其中没有节点")
                        }
                    } else {
                        outcome = .transportFailure(result.message)
                    }
                } catch {
                    // Sibling cancellation is not a real transport failure.
                    let message = error.localizedDescription
                    outcome = message.contains("取消") ? .transportFailure("") : .transportFailure(message)
                }
                lock.lock()
                switch outcome {
                case .success(let fetched):
                    let isFirst = winner == nil
                    if isFirst { winner = fetched }
                    lock.unlock()
                    if isFirst { semaphore.signal() }
                case .contentFailure(let message):
                    if winner == nil { contentFailure = message }
                    lock.unlock()
                case .transportFailure(let message):
                    if winner == nil, !message.isEmpty, transportFailure.isEmpty { transportFailure = message }
                    lock.unlock()
                }
            }
        }
        let deadline = Date().addingTimeInterval(17)
        while Date() < deadline {
            if semaphore.wait(timeout: .now() + 0.05) == .success { break }
            try checkCancellation()
        }
        roundCancellation.cancel()
        _ = group.wait(timeout: .now() + 2)
        try checkCancellation()
        lock.lock()
        let fetched = winner
        let content = contentFailure
        let transport = transportFailure
        lock.unlock()
        if let fetched { return .success(fetched) }
        if let content { return .contentFailure(content) }
        return .transportFailure(transport.isEmpty ? "下载超时" : transport)
    }

    static func subscriptionYAMLURL(in directory: URL) -> URL {
        directory.appendingPathComponent("subscription.yaml")
    }

    private static func parse(data: Data) -> SubscriptionSnapshot? {
        guard let text = String(data: data, encoding: .utf8),
              let yaml = SubscriptionParser.normalize(text) else { return nil }
        let nodes = SubscriptionParser.nodes(in: yaml)
        return SubscriptionSnapshot(nodes: nodes, userInfo: "")
    }

    private static func headerValue(_ name: String, in url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var found: String?
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name {
                found = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return found
    }

    private struct CurlOutcome: Sendable {
        let status: Int32
        let message: String
    }

    private static func runCurl(url: String, proxy: SubscriptionDownloadProxy?, body: URL, headers: URL,
                                ipv4Only: Bool,
                                checkCancellation: () throws -> Void) throws -> CurlOutcome {
        let request = SubscriptionCurlRequest(url: url, proxy: proxy)
        let configURL = body.deletingLastPathComponent()
            .appendingPathComponent("subscription-curl-" + UUID().uuidString + ".conf")
        try AppPaths.writePrivate(Data(request.configText.utf8), to: configURL)
        defer { try? FileManager.default.removeItem(at: configURL) }
        var arguments = ["-q", "--config", configURL.path,
                         "--fail", "--silent", "--show-error", "--location", "--http1.1", "--compressed",
                         "--proto", "=http,https", "--proto-redir", "=http,https",
                         "--connect-timeout", "4", "--max-time", "14", "--max-redirs", "3",
                         "--max-filesize", String(maximumBodyBytes),
                         "--user-agent", "Clash.Meta/" + CoreInstaller.version,
                         "--header", "Accept: application/yaml, text/yaml, text/plain, */*",
                         "--dump-header", headers.path, "--output", body.path]
        if ipv4Only { arguments.append("-4") }
        if proxy != nil { arguments += ["--noproxy", ""] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try checkCancellation()
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        do {
            while process.isRunning {
                try checkCancellation()
                if Date() >= deadline {
                    terminate(process)
                    return CurlOutcome(status: -1, message: "订阅下载超时")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } catch {
            terminate(process)
            throw error
        }
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = message.components(separatedBy: .newlines).last.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            return CurlOutcome(status: process.terminationStatus,
                               message: detail.isEmpty ? "curl 退出码 \(process.terminationStatus)" : detail)
        }
        return CurlOutcome(status: 0, message: "")
    }

    /// Small cancellation flag used to stop sibling fetch workers; it lives here so this
    /// file stays free of the launcher's runtime types (and can be unit tested alone).
    private final class FetchCancellation: @unchecked Sendable {
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
            if value { throw UserFacingError("操作已取消。") }
        }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
