import AppKit

/// An installed Antigravity-family application that the launcher can start.
struct InstalledApplication: Equatable {
    let url: URL
    let name: String
    let version: String
    let bundleIdentifier: String

    var displayName: String {
        version.isEmpty ? name : "\(name) \(version)"
    }
}

enum ApplicationLocator {
    /// Both shipping editions share Google's Antigravity bundle prefix:
    /// `com.google.antigravity` (Antigravity) and `com.google.antigravity-ide` (Antigravity IDE).
    static let preferredBundleIdentifiers = ["com.google.antigravity", "com.google.antigravity-ide"]

    static func isSupported(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == "com.google.antigravity"
            || bundleIdentifier == "com.google.antigravity-ide"
            || bundleIdentifier.hasPrefix("com.google.antigravity.")
    }

    static func isApplication(at url: URL) -> Bool {
        guard url.pathExtension == "app", let executable = Bundle(url: url)?.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }

    /// Finds every installed Antigravity edition (Antigravity, Antigravity IDE, ...).
    /// Third-party helpers such as "Antigravity Tools" are excluded by bundle identifier.
    static func installedApplications() -> [InstalledApplication] {
        var candidates: [URL] = []
        let fileManager = FileManager.default
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            candidates.append(contentsOf: entries.filter { $0.pathExtension == "app" })
        }
        for identifier in preferredBundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                candidates.append(url)
            }
        }
        var seen = Set<String>()
        var applications: [InstalledApplication] = []
        for url in candidates {
            let standardized = url.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(standardized.path).inserted,
                  let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier,
                  isSupported(identifier),
                  let executable = bundle.executableURL,
                  fileManager.isExecutableFile(atPath: executable.path) else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            applications.append(InstalledApplication(url: standardized, name: name,
                                                     version: version, bundleIdentifier: identifier))
        }
        applications.sort { lhs, rhs in
            let lhsPriority = preferredBundleIdentifiers.firstIndex(of: lhs.bundleIdentifier) ?? Int.max
            let rhsPriority = preferredBundleIdentifiers.firstIndex(of: rhs.bundleIdentifier) ?? Int.max
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.url.path < rhs.url.path
        }
        return applications
    }

    static func locate(preferredPath: String) -> URL? {
        let candidates: [URL?] = [
            URL(fileURLWithPath: preferredPath),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity"),
            installedApplications().first?.url,
            URL(fileURLWithPath: "/Applications/Antigravity.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Antigravity.app")
        ]
        return candidates.compactMap { $0 }.first(where: isApplication)
    }
}
