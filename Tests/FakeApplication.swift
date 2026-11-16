// Optional GUI fixture: records only test proxy values and supports normal quit.
import AppKit
import Foundation

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let keys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                    "http_proxy", "https_proxy", "all_proxy", "no_proxy"]
        var values: [String: Any] = [:]
        for key in keys { values[key] = ProcessInfo.processInfo.environment[key] ?? "" }
        values["arguments"] = Array(CommandLine.arguments.dropFirst())
        let output = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("app-environment.json")
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
            try? data.write(to: output)
        }
    }
}

@main
struct FixtureMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        withExtendedLifetime(delegate) { app.run() }
    }
}
