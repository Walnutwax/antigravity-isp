import Foundation
import CryptoKit
import Darwin

enum CoreInstaller {
    static let version = "v1.19.34"
    #if arch(arm64)
    static let asset = "mihomo-darwin-arm64-v1.19.34.gz"
    static let archiveSHA256 = "1a7a20eca63fbbaec90137717465bfde488d0db2a3a79b8fadebf9b2545b6e4c"
    #else
    static let asset = "mihomo-darwin-amd64-compatible-v1.19.34.gz"
    static let archiveSHA256 = "703bceaa494732fa456f47e6ac2f06bf0bc5593d4c927d5f61e10f1a31039c37"
    #endif
    static let sourceURL = "https://github.com/MetaCubeX/mihomo/releases/tag/" + version

    static func ensureInstalled(progress: @escaping (String) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            if FileManager.default.isExecutableFile(atPath: AppPaths.mihomoExecutable.path) {
                progress("代理内核已安装。")
                return
            }
            try AppPaths.createPrivateDirectory(AppPaths.supportDirectory)
            let directory = AppPaths.supportDirectory.appendingPathComponent(".core-install-" + UUID().uuidString)
            try AppPaths.createPrivateDirectory(directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let archive = directory.appendingPathComponent("mihomo.gz")
            let binary = directory.appendingPathComponent("mihomo")
            let url = "https://github.com/MetaCubeX/mihomo/releases/download/" + version + "/" + asset
            progress("正在从 Mihomo 官方仓库下载代理内核…")
            let download = Process()
            download.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            download.arguments = ["-q", "--fail", "--silent", "--show-error", "--location",
                                  "--proto", "=https", "--proto-redir", "=https",
                                  "--connect-timeout", "15", "--max-time", "90",
                                  "--retry", "1", "--output", archive.path, url]
            download.standardOutput = FileHandle.nullDevice
            download.standardError = FileHandle.nullDevice
            try download.run()
            download.waitUntilExit()
            guard download.terminationStatus == 0 else {
                throw UserFacingError("下载未完成，请确认本机能够访问 GitHub 后重试。官方内核下载地址见项目 README。")
            }
            progress("正在校验下载文件…")
            let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard verifiedArchive(bytes) else {
                throw UserFacingError("下载文件校验失败，未安装或执行该文件。请稍后重试。")
            }
            guard FileManager.default.createFile(atPath: binary.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw UserFacingError("无法创建内核安装文件。")
            }
            let output = try FileHandle(forWritingTo: binary)
            defer { try? output.close() }
            let unpack = Process()
            unpack.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            unpack.arguments = ["-dc", archive.path]
            unpack.standardOutput = output
            unpack.standardError = FileHandle.nullDevice
            try unpack.run()
            unpack.waitUntilExit()
            try output.synchronize()
            guard unpack.terminationStatus == 0 else { throw UserFacingError("代理内核解压失败。") }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            let verify = Process()
            verify.executableURL = binary
            verify.arguments = ["-v"]
            verify.standardOutput = FileHandle.nullDevice
            verify.standardError = FileHandle.nullDevice
            try verify.run()
            verify.waitUntilExit()
            guard verify.terminationStatus == 0 else { throw UserFacingError("此代理内核不能在当前 Mac 上运行。") }
            try AppPaths.createPrivateDirectory(AppPaths.mihomoExecutable.deletingLastPathComponent())
            guard rename(binary.path, AppPaths.mihomoExecutable.path) == 0 else {
                throw UserFacingError("无法完成代理内核安装。")
            }
            let receipt: [String: String] = ["version": version, "asset": asset,
                                            "sha256": archiveSHA256, "source": sourceURL,
                                            "license": "GPL-3.0"]
            try AppPaths.writePrivate(JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]),
                                      to: AppPaths.supportDirectory.appendingPathComponent("core-receipt.json"))
            progress("代理内核已安装并通过校验。")
        }.value
    }

    static func verifiedArchive(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == archiveSHA256
    }
}
