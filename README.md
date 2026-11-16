# Antigravity ISP

[English](README.en.md)

给 Antigravity 单独配置代理，一键启动，保持系统代理不变。支持带认证的远程 HTTP、HTTPS、SOCKS5 代理，无需先手动启动通用代理客户端。

这是一个原生 macOS 启动器。安装官方 Antigravity 并填写自己的上游代理后，它会管理本地转发进程，并带着对应代理设置启动 Antigravity。

本项目是独立工具，与 Antigravity 官方没有关联。它不提供代理节点、账号或服务资格，也不承诺改变账号可用性、地区资格或服务端风控结果。

## 工作方式

```text
Antigravity + 遵循代理设置的子进程
                │
                ▼
       127.0.0.1:17898
       本工具启动的 Mihomo
                │
                ▼
      你的 HTTP / HTTPS / SOCKS5 上游
```

- 原生 Swift/AppKit 界面，无 Python 运行时。
- 支持上游协议、地址、端口、用户名及密码配置；密码保存在 macOS 钥匙串中。
- 自动管理专用本地转发进程，可配置本地端口、目标应用路径和启动器打开后的自动启动。
- 支持连接测试及可选的预期出口 IP，用于核对测试请求实际看到的出口。
- 作为普通 Dock 应用运行，使用本项目原创图标。

它不启用 TUN，不修改系统代理或全局环境变量，也不是虚拟机或网络隔离沙箱。代理范围取决于 Antigravity 及子进程是否遵循相应代理参数和环境变量。外部浏览器、已有进程及忽略代理设置的扩展或命令行工具可能使用其他网络路径。连接测试结果只证明该测试请求的路径，不代表应用中每个请求都经过代理。

## 系统要求

- macOS 13 或更新版本。
- 已单独安装的官方 Antigravity 应用。
- 可用的 HTTP、HTTPS 或 SOCKS5 上游代理。
- 首次安装代理内核时，本机网络需要能够访问 GitHub；这次下载不会通过尚未启动的本地转发。后续启动可使用已校验的本地内核。
- 从源码构建需要 Xcode Command Line Tools，使用 `xcode-select --install` 安装。

## 从源码构建

在本仓库目录执行：

```sh
./scripts/test.sh
./scripts/build.sh
open "dist/Antigravity ISP.app"
```

输出为 `dist/Antigravity ISP.app`，可将其拖入“应用程序”文件夹。构建脚本不下载代理内核、不需要 Python，也不需要代理凭据。它调用系统 Swift 编译器，使用 Swift 5 语言模式、AppKit/Cocoa 和 Security 框架。

默认按当前 Mac 的架构构建：Apple Silicon 为 `arm64`，Intel 为 `x86_64`；输出不是通用二进制。CI 配置分别使用 GitHub 的 `macos-15` 和 `macos-15-intel` 运行器，测试后生成对应架构的 ZIP 和 SHA-256 文件。CI 尚未运行；后续结果以仓库 Actions 为准。

当前构建仅使用本地临时签名（ad-hoc），没有 Developer ID 签名或 Apple 公证。下载的构建可能被 Gatekeeper 拦截。确认来源和内容可信后，可按 macOS 提示在“系统设置 → 隐私与安全性”中使用“仍要打开”；也可以自行审阅并从源码构建。

## 配置与使用

1. 首次使用先点击“安装代理内核”，等待固定版本的 Mihomo 下载并通过校验。这一步使用本机当前网络访问 GitHub。
2. 选择已安装的 Antigravity `.app` 路径。
3. 填写上游协议、服务器、端口；需要认证时填写用户名和密码。
4. 保留默认本地端口 `17898`，或选择其他未被占用的端口。
5. 可选填预期出口 IP。留空时只查看实际出口；填写后用于与测试结果比对。
6. 保存配置并测试连接，然后通过启动器启动 Antigravity。

如果 Antigravity 已在运行，应先正常退出，再通过启动器启动，使新进程获得代理设置。“自动启动”指打开本启动器后自动启动代理和目标应用，不会将应用添加到 macOS 登录项。

不要将含有代理地址、用户名或密码的截图和日志直接提交到公开 Issue。

## 数据与内核

设置与运行文件位于当前用户的专用目录：

```text
~/Library/Application Support/AntigravityISP/
```

密码使用 macOS 钥匙串保存：service 为 `io.github.antigravity-isp.proxy`，account 为 `default`。运行期间 Mihomo 需要读取代理认证信息，因此会生成权限为 `0600` 的临时配置；正常停止或退出时删除该配置。强制终止或系统崩溃可能中断退出清理。

点击“安装代理内核”后，本工具从 [Mihomo 官方 v1.19.34 发布页](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34)获取与机器架构对应的固定版本，并按代码中固定的 SHA-256 校验下载内容。内核存放于上述目录的 `bin/` 中。仓库和生成的 `.app` 均不包含 Mihomo 二进制，也不包含真实代理凭据。

Mihomo 按 GPLv3 提供；其源码、许可证和版本对应关系见 [第三方声明](THIRD_PARTY_NOTICES.md)。本项目的 MIT 许可证只覆盖本项目自有代码与素材，不改变第三方组件的许可证。

## 验证状态

公开版 0.1.0 已在 macOS 26.7.3、Apple Silicon 上完成：

- `arm64` 构建及本地签名校验。
- 配置模型、私有文件权限、内核篡改检测，以及使用隔离测试目录的运行生命周期测试。
- 使用原生测试 `.app` 验证真实 Launch Services 启动时的参数、环境变量传递和正常退出清理。
- 界面首次启动、高级设置和空表单校验的实际操作验证。
- 从官方源下载 Mihomo v1.19.34，按固定 SHA-256 校验并成功运行内核。
- 使用公开版运行代码、官方 Mihomo 和真实远程上游完成连接测试，预期出口匹配；停止后临时认证配置剩余 0 个。

公开版的新进程启动流程通过原生测试 `.app` 验证，尚未针对真实 Antigravity 的模型请求做端到端验证。Intel、macOS 13 的实际运行尚未本机验证，GitHub CI 尚未运行。

原型记录：早期个人版本曾在同一环境中针对 Antigravity 2.32.1 完成真实应用验证；这与上述公开版验证分开记录。

## 常见问题

**首次下载失败**：检查当前网络是否能访问 GitHub 官方发布资源，再重试。校验不匹配的内核不会被使用。

**本地端口已占用**：选择其他未占用的本地端口并保存，然后重新启动代理。

**强制退出后仍有代理进程或临时配置**：强杀或系统崩溃可能留下本工具启动的代理进程和临时配置。确认进程的可执行文件位于本工具的专用目录后再处理；本工具不会仅按端口号自动杀死进程。处理前保留其他代理客户端和不相关进程。

**出口 IP 与预期不同**：核对上游配置和代理服务的出口策略。某些服务会轮换出口 IP；预期 IP 应与所用服务一致。

**连接测试成功，但应用仍无法使用**：检查应用是否通过启动器重新启动，以及失败请求是否来自外部浏览器、扩展或独立工具。代理连通不等于账号或服务资格验证成功。

## 卸载

先停止转发并退出启动器，再删除 `Antigravity ISP.app`。如需清除本工具保存的数据，删除 `~/Library/Application Support/AntigravityISP/`，并在“钥匙串访问”中删除 service 为 `io.github.antigravity-isp.proxy`、account 为 `default` 的密码项。

这些是本工具专用的数据。保留官方 Antigravity 应用及其用户数据。

## 参与开发

应用源码位于 [Sources](Sources)，构建脚本位于 [scripts](scripts)。修改后运行 `./scripts/test.sh` 和 `./scripts/build.sh`。不要在测试、配置样例、截图或提交记录中放入真实凭据和个人配置。

本项目自有代码与图标使用 [MIT 许可证](LICENSE)。第三方组件和官方产品的名称、商标及许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
