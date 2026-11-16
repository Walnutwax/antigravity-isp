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
        print("PASS: invalid configurations, self-proxy loop, password-free settings, tampered core, private atomic writes")
    }

    static func expectFailure(_ reason: String, operation: () throws -> Void) throws {
        do { try operation() }
        catch { return }
        throw UserFacingError(reason)
    }
}
