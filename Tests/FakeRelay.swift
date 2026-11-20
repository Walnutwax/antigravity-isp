// A native loopback listener for runtime ownership tests. It never connects out.
import Darwin
import Foundation

guard let option = CommandLine.arguments.firstIndex(of: "-f"),
      option + 1 < CommandLine.arguments.count else { exit(3) }

let configURL = URL(fileURLWithPath: CommandLine.arguments[option + 1])
func readConfig() -> [String: Any]? {
    guard let data = try? Data(contentsOf: configURL) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

guard let config = readConfig(),
      let port = config["mixed-port"] as? Int,
      let proxies = config["proxies"] as? [[String: Any]] else { exit(3) }

if CommandLine.arguments.contains("-t") {
    let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path)
    guard (attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600,
          let rules = config["rules"] as? [String] else { exit(19) }
    if rules.contains("DOMAIN,fail-preflight.example.invalid,DIRECT") {
        print("synthetic diagnostic payload")
        exit(21)
    }
    if rules.contains("DOMAIN,slow-preflight.example.invalid,DIRECT") {
        Thread.sleep(forTimeInterval: 5)
    }
    exit(0)
}

let server = proxies.first?["server"] as? String
if server == "exit.invalid" { exit(17) }
if server == "slow.invalid" { Thread.sleep(forTimeInterval: 5) }

signal(SIGHUP, SIG_IGN)
let reloads = DispatchSource.makeSignalSource(signal: SIGHUP, queue: DispatchQueue.global())
reloads.setEventHandler {
    guard let rules = readConfig()?["rules"] as? [String],
          let data = try? JSONEncoder().encode(rules) else { return }
    let observed = configURL.deletingLastPathComponent().appendingPathComponent("observed-rules.json")
    try? data.write(to: observed, options: [.atomic])
}
reloads.activate()

let descriptor = socket(AF_INET, SOCK_STREAM, 0)
guard descriptor >= 0 else { exit(4) }
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = in_port_t(port).bigEndian
address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bound == 0, listen(descriptor, 8) == 0 else { exit(5) }
while true { pause() }
