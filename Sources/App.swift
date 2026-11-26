import AppKit
import UniformTypeIdentifiers

@main
struct AntigravityISPApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let controller = LauncherController()
    private var window: NSWindow!
    private var controllerBusy = false
    private var installingCore = false
    private var terminationPending = false
    private var installationTask: Task<Void, Never>?

    private let sourceControl = NSSegmentedControl(labels: ["订阅链接", "手动代理"],
                                                   trackingMode: .selectOne, target: nil, action: nil)
    private let subscriptionField = NSTextField()
    private let subscriptionNodePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshNodesButton = NSButton()
    private let subscriptionProxyButton = NSButton(checkboxWithTitle: "通过下方手动代理下载订阅（本机直连失败时）", target: nil, action: nil)
    private let chainManualProxyButton = NSButton(checkboxWithTitle: "链式落地：经订阅节点中转至下方静态代理（dialer-proxy）", target: nil, action: nil)
    private var subscriptionFields: NSStackView!
    private var subscriptionCatalog: SubscriptionCatalog?
    private var fetchingNodes = false
    private var nodeRefreshCancellation: RuntimeCancellation?
    private var manualFields: NSStackView!
    private let useRelayURIButton = NSButton(checkboxWithTitle: "启用加密中转节点（VLESS Reality / TLS → 下方静态代理）", target: nil, action: nil)
    private let relayURIField = NSSecureTextField()
    private var relayURIRow: NSStackView!
    private let splitModelTrafficButton = NSButton(checkboxWithTitle: "链式三路分流：仅模型/AI 域名走落地代理，其余流量走中转节点", target: nil, action: nil)
    private let protocolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let serverField = NSTextField()
    private let portField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let expectedExitIPField = NSTextField()
    private let localPortField = NSTextField()
    private let directDomainsField = NSTextField()
    private let directDomainSuffixesField = NSTextField()
    private let applyRoutingButton = NSButton()
    private let appPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appPathLabel = NSTextField(labelWithString: "")
    private var detectedApplications: [InstalledApplication] = []
    private var customApplicationPath = ""
    private let autoStartButton = NSButton(checkboxWithTitle: "打开本工具时自动启动 Antigravity", target: nil, action: nil)
    private let themeButton = NSButton(checkboxWithTitle: "启用 Codex Theme、汉化和会话统计", target: nil, action: nil)
    private let themeNodeField = NSTextField()
    private var themeRuntimeFields: NSStackView!
    private let advancedButton = NSButton()
    private var advancedFields: NSStackView!
    private var editableControls: [NSControl] = []

    private let statusImage = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "先填写代理信息，再测试连接。")
    private let progressIndicator = NSProgressIndicator()
    private let installButton = NSButton()
    private let importCoreButton = NSButton()
    private let importProxyButton = NSButton()
    private let setupLabel = NSTextField(wrappingLabelWithString: "")
    private let browseButton = NSButton()
    private let saveButton = NSButton()
    private let testButton = NSButton()
    private let launchButton = NSButton()
    private let stopButton = NSButton()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A refresh interrupted by a quit/crash may leave a partial download behind.
        AppPaths.cleanupAbandonedRefreshDirectories()
        buildMenu()
        buildWindow()
        subscriptionCatalog = SettingsStore.loadSubscriptionCatalog()
        controller.onSubscriptionNodes = { [weak self] nodes in
            self?.storeSubscriptionNodes(nodes)
        }
        controller.onStatusChange = { [weak self] message, busy in
            guard let self else { return }
            self.controllerBusy = busy
            self.setStatus(message)
            self.updateControls()
        }
        controller.onStopCompletion = { [weak self] succeeded in
            // A no-op stop may complete immediately, before terminateLater is returned.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.terminationPending else { return }
                self.terminationPending = false
                NSApp.reply(toApplicationShouldTerminate: succeeded)
                if !succeeded {
                    self.showSettings()
                    self.showAlert(
                        title: "Antigravity 仍在运行",
                        message: "请先在 Antigravity 中完成保存并退出，再退出本工具。代理会继续运行。"
                    )
                }
            }
        }

        var loadedSettings: ProxySettings?
        do {
            var settings = try SettingsStore.load()
            if let applicationURL = ApplicationLocator.locate(preferredPath: settings.appPath) {
                settings.appPath = applicationURL.path
            }
            populate(settings, password: "")
            do {
                passwordField.stringValue = try SettingsStore.loadPassword()
                subscriptionField.stringValue = try SettingsStore.loadSubscriptionURL()
                relayURIField.stringValue = try SettingsStore.loadRelayURI()
                loadedSettings = settings
            } catch {
                setStatus("已读取代理设置，请重新填写密码或解锁钥匙串。")
                showSettings()
                showError(error)
            }
        } catch {
            populate(ProxySettings(), password: "")
            setStatus("无法读取已保存的设置。请检查后重新保存。")
            showSettings()
            showError(error)
        }
        updateControls()
        showSettings()

        if let settings = loadedSettings {
            prefetchSubscriptionIfNeeded(settings)
        }
        if let settings = loadedSettings, settings.autoStart {
            do {
                try SettingsValidator.validate(settings)
                if coreIsInstalled {
                    controller.start(settings: settings, password: passwordField.stringValue,
                                     subscriptionURL: subscriptionField.stringValue,
                                     relayURI: relayURIValue)
                } else {
                    setStatus("请先安装代理内核，再启动 Antigravity。")
                }
            } catch {
                setStatus("请补全代理设置后再启动 Antigravity。")
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending {
            return .terminateLater
        }
        if installingCore {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "正在安装代理内核，安装完成后退出？"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "完成后退出")
            showSettings()
            guard alert.runModal() == .alertSecondButtonReturn else {
                return .terminateCancel
            }
            // Installation may finish while the confirmation runs its modal loop.
            guard installingCore else { return .terminateNow }
            terminationPending = true
            setStatus("正在安装代理内核，完成后将自动退出。")
            return .terminateLater
        }
        guard controller.isRunning || controllerBusy || fetchingNodes else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = controller.hasRunningApplication ? "退出 Antigravity 和代理？" : "结束当前操作并退出？"
        alert.informativeText = controller.hasRunningApplication
            ? "本工具需要先退出 Antigravity，才能停止代理。请先保存应用中的工作；若 Antigravity 未退出，代理会继续运行。"
            : "当前连接操作将停止，随后退出本工具。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: controller.hasRunningApplication ? "先退出 Antigravity" : "结束并退出")
        showSettings()
        guard alert.runModal() == .alertSecondButtonReturn else {
            return .terminateCancel
        }
        terminationPending = true
        nodeRefreshCancellation?.cancel()
        controller.stop()
        return .terminateLater
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveSettings) || menuItem.action == #selector(testConnection) {
            return !isBusy
        }
        return true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem(title: "Antigravity ISP", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Antigravity ISP")
        applicationMenu.addItem(withTitle: "关于 Antigravity ISP", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        let settingsItem = applicationMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "隐藏 Antigravity ISP", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = applicationMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出 Antigravity ISP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let connectionItem = NSMenuItem(title: "连接", action: nil, keyEquivalent: "")
        let connectionMenu = NSMenu(title: "连接")
        let saveItem = connectionMenu.addItem(withTitle: "保存设置", action: #selector(saveSettings), keyEquivalent: "s")
        saveItem.target = self
        let testItem = connectionMenu.addItem(withTitle: "测试连接", action: #selector(testConnection), keyEquivalent: "t")
        testItem.target = self
        connectionItem.submenu = connectionMenu
        mainMenu.addItem(connectionItem)

        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Antigravity ISP"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 600)
        window.delegate = self
        window.setFrameAutosaveName("AntigravityISPSettingsV2")
        window.center()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        window.contentView!.addSubview(scrollView)
        let footer = verticalStack(spacing: 10)
        window.contentView!.addSubview(footer)
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        addFullWidth(footerSeparator, to: footer)
        addFullWidth(makeStatusPanel(), to: footer)
        addFullWidth(makeActions(), to: footer)
        let closeHint = label("关闭窗口会继续运行；停止时会先退出 Antigravity。", size: 11, color: .secondaryLabelColor)
        closeHint.alignment = .right
        addFullWidth(closeHint, to: footer)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            footer.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        let content = verticalStack(spacing: 18)
        documentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])

        addFullWidth(makeHeader(), to: content)
        addFullWidth(makeProxyPanel(), to: content)
        addFullWidth(makeApplicationPanel(), to: content)
        window.defaultButtonCell = launchButton.cell as? NSButtonCell
    }

    private func makeHeader() -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 31, weight: .medium)
        symbol.contentTintColor = .controlAccentColor
        symbol.setAccessibilityElement(false)
        symbol.widthAnchor.constraint(equalToConstant: 44).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let text = verticalStack(spacing: 5)
        text.addArrangedSubview(label("Antigravity ISP", size: 23, weight: .semibold))
        text.addArrangedSubview(label("只为 Antigravity 配置代理，保持系统代理不变", size: 12, color: .secondaryLabelColor))
        return horizontalStack([symbol, text], spacing: 13)
    }

    private func makeProxyPanel() -> NSView {
        let fields = verticalStack(spacing: 11)
        addFullWidth(label("上游代理", size: 14, weight: .semibold), to: fields)
        sourceControl.segmentStyle = .rounded
        sourceControl.selectedSegment = 0
        sourceControl.target = self
        sourceControl.action = #selector(changeSource)
        sourceControl.setAccessibilityLabel("代理来源")
        sourceControl.widthAnchor.constraint(equalToConstant: 220).isActive = true
        editableControls.append(sourceControl)
        addFullWidth(formRow("代理来源", field: horizontalStack([sourceControl, NSView()], spacing: 0)), to: fields)

        subscriptionFields = verticalStack(spacing: 12)
        configureField(subscriptionField, placeholder: "粘贴 Clash / Mihomo 订阅链接", accessibility: "订阅地址")
        subscriptionField.toolTip = "订阅链接保存在本机钥匙串"
        let pasteSubscription = NSButton()
        configureButton(pasteSubscription, title: "粘贴", action: #selector(importSubscription))
        pasteSubscription.toolTip = "从剪贴板读取订阅链接"
        editableControls.append(pasteSubscription)
        addFullWidth(formRow("订阅地址",
                             field: horizontalStack([subscriptionField, pasteSubscription], spacing: 8)),
                     to: subscriptionFields)

        configureButton(refreshNodesButton, title: "刷新节点", action: #selector(refreshSubscriptionNodes))
        refreshNodesButton.toolTip = "重新获取订阅并读取节点列表；直连失败时可勾选下方“通过手动代理下载订阅”"
        editableControls.append(refreshNodesButton)
        subscriptionNodePopup.font = .systemFont(ofSize: 13)
        subscriptionNodePopup.setAccessibilityLabel("订阅节点")
        subscriptionNodePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subscriptionNodePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subscriptionNodePopup.toolTip = "默认自动选择延迟最低的节点，也可以固定使用某个节点"
        editableControls.append(subscriptionNodePopup)
        addFullWidth(formRow("节点",
                             field: horizontalStack([subscriptionNodePopup, refreshNodesButton], spacing: 8)),
                     to: subscriptionFields)
        let subscriptionHint = NSTextField(wrappingLabelWithString:
            "支持 Clash/Mihomo YAML 批量订阅（含 Base64 编码），订阅地址保存在本机钥匙串。\n刷新节点后可在这里快速切换；每次测试或启动前都会重新获取订阅。")
        subscriptionHint.font = .systemFont(ofSize: 11)
        subscriptionHint.textColor = .secondaryLabelColor
        addFullWidth(subscriptionHint, to: subscriptionFields)
        subscriptionProxyButton.font = .systemFont(ofSize: 12)
        subscriptionProxyButton.target = self
        subscriptionProxyButton.action = #selector(changeSource)
        editableControls.append(subscriptionProxyButton)
        addFullWidth(subscriptionProxyButton, to: subscriptionFields)
        chainManualProxyButton.font = .systemFont(ofSize: 12)
        chainManualProxyButton.target = self
        chainManualProxyButton.action = #selector(changeSource)
        chainManualProxyButton.toolTip = "订阅节点作为加密中转（RELAY），经 dialer-proxy 转发至下方手动静态代理落地"
        editableControls.append(chainManualProxyButton)
        addFullWidth(chainManualProxyButton, to: subscriptionFields)
        addFullWidth(subscriptionFields, to: fields)

        manualFields = verticalStack(spacing: 11)
        useRelayURIButton.font = .systemFont(ofSize: 12)
        useRelayURIButton.target = self
        useRelayURIButton.action = #selector(changeSource)
        useRelayURIButton.toolTip = "使用自建 VLESS Reality / TLS 节点作为加密中转，减少明文 HTTP 代理跨境被 RST 重置"
        editableControls.append(useRelayURIButton)
        addFullWidth(useRelayURIButton, to: manualFields)

        configureField(relayURIField, placeholder: "vless://UUID@host:443?security=reality&sni=...&pbk=...&sid=...", accessibility: "加密中转链接")
        relayURIField.toolTip = "中转节点链接保存在本机钥匙串，不写入明文设置文件"
        let pasteRelay = NSButton()
        configureButton(pasteRelay, title: "粘贴", action: #selector(importRelayURI))
        pasteRelay.toolTip = "从剪贴板导入 vless:// Reality 或 TLS 链接"
        editableControls.append(pasteRelay)
        relayURIRow = formRow("中转链接", field: horizontalStack([relayURIField, pasteRelay], spacing: 8))
        addFullWidth(relayURIRow, to: manualFields)

        configureButton(importProxyButton, title: "从剪贴板导入", action: #selector(importProxy))
        importProxyButton.toolTip = "导入 http://、https://、socks5:// 或服务器:端口；支持链接中的账号密码"
        editableControls.append(importProxyButton)
        addFullWidth(horizontalStack([
            importProxyButton,
            label("粘贴代理链接，自动填写下方信息", size: 11, color: .secondaryLabelColor),
            NSView()
        ], spacing: 8), to: manualFields)
        protocolPopup.addItems(withTitles: ["HTTP", "HTTPS", "SOCKS5"])
        for (index, value) in ["http", "https", "socks5"].enumerated() {
            protocolPopup.item(at: index)?.representedObject = value
        }
        protocolPopup.widthAnchor.constraint(equalToConstant: 132).isActive = true
        protocolPopup.setAccessibilityLabel("代理协议")
        let protocolRow = horizontalStack([protocolPopup, NSView()], spacing: 0)
        addFullWidth(formRow("协议", field: protocolRow), to: manualFields)

        configureField(serverField, placeholder: "proxy.example.com", accessibility: "代理服务器")
        configureField(portField, placeholder: "8080", accessibility: "代理端口")
        portField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let portLabel = label("端口", size: 12, color: .secondaryLabelColor)
        portLabel.setContentHuggingPriority(.required, for: .horizontal)
        let serverAndPort = horizontalStack([serverField, portLabel, portField], spacing: 10)
        addFullWidth(formRow("服务器", field: serverAndPort), to: manualFields)
        configureField(usernameField, placeholder: "可选", accessibility: "代理用户名")
        addFullWidth(formRow("用户名", field: usernameField), to: manualFields)
        configureField(passwordField, placeholder: "可选", accessibility: "代理密码")
        addFullWidth(formRow("密码", field: passwordField), to: manualFields)
        addFullWidth(formRow("", field: label("密码与中转链接保存在此 Mac 的钥匙串中。", size: 11, color: .secondaryLabelColor)), to: manualFields)
        addFullWidth(manualFields, to: fields)

        splitModelTrafficButton.font = .systemFont(ofSize: 12)
        splitModelTrafficButton.toolTip = "开启后，仅模型/AI 核心域名与出口探测经链式落地代理，普通海外流量直接走中转节点"
        editableControls.append(splitModelTrafficButton)
        addFullWidth(splitModelTrafficButton, to: fields)

        advancedButton.title = "高级设置"
        advancedButton.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)
        advancedButton.imagePosition = .imageLeading
        advancedButton.imageHugsTitle = true
        advancedButton.isBordered = false
        advancedButton.bezelStyle = .inline
        advancedButton.font = .systemFont(ofSize: 12)
        advancedButton.target = self
        advancedButton.action = #selector(toggleAdvanced)
        advancedButton.setAccessibilityLabel("展开高级设置")
        let advancedHeader = horizontalStack([
            advancedButton,
            label("出口 IP、端口与直连分流", size: 11, color: .secondaryLabelColor),
            NSView()
        ], spacing: 8)
        addFullWidth(advancedHeader, to: fields)

        advancedFields = verticalStack(spacing: 11)
        configureField(expectedExitIPField, placeholder: "可选，用于核对代理出口", accessibility: "预期出口 IP")
        addFullWidth(formRow("预期出口 IP", field: expectedExitIPField), to: advancedFields)
        configureField(localPortField, placeholder: "17898", accessibility: "本地端口")
        localPortField.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let localPortRow = horizontalStack([
            localPortField,
            label("仅供本工具连接", size: 11, color: .secondaryLabelColor),
            NSView()
        ], spacing: 10)
        addFullWidth(formRow("本地端口", field: localPortRow), to: advancedFields)
        configureField(directDomainsField, placeholder: "例如 portal.example.com", accessibility: "精确直连域名")
        addFullWidth(formRow("精确直连域名", field: directDomainsField), to: advancedFields)
        configureField(directDomainSuffixesField, placeholder: "例如 internal.example.org（含子域名）", accessibility: "直连域名后缀")
        addFullWidth(formRow("直连域名后缀", field: directDomainSuffixesField), to: advancedFields)
        let routingHint = NSTextField(wrappingLabelWithString:
            "多个域名可用逗号或空格分隔。留空时，代理请求均走上游。运行期间可应用分流，新规则用于后续连接。")
        routingHint.font = .systemFont(ofSize: 11)
        routingHint.textColor = .secondaryLabelColor
        addFullWidth(routingHint, to: advancedFields)
        configureButton(applyRoutingButton, title: "应用分流", action: #selector(applyRouting))
        addFullWidth(formRow("", field: horizontalStack([applyRoutingButton, NSView()], spacing: 0)), to: advancedFields)
        addFullWidth(advancedFields, to: fields)
        advancedFields.isHidden = true
        editableControls.append(protocolPopup)
        return panel(fields)
    }

    private func makeApplicationPanel() -> NSView {
        let fields = verticalStack(spacing: 11)
        addFullWidth(label("Antigravity", size: 14, weight: .semibold), to: fields)
        appPopup.font = .systemFont(ofSize: 13)
        appPopup.setAccessibilityLabel("启动应用")
        appPopup.target = self
        appPopup.action = #selector(applicationSelectionChanged)
        appPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        appPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editableControls.append(appPopup)
        configureButton(browseButton, title: "选择…", action: #selector(browseApplication))
        browseButton.setContentHuggingPriority(.required, for: .horizontal)
        browseButton.toolTip = "选择没有被自动检测到的 Antigravity.app"
        addFullWidth(formRow("启动应用", field: horizontalStack([appPopup, browseButton], spacing: 8)), to: fields)
        appPathLabel.font = .systemFont(ofSize: 11)
        appPathLabel.textColor = .secondaryLabelColor
        appPathLabel.lineBreakMode = .byTruncatingMiddle
        appPathLabel.maximumNumberOfLines = 1
        addFullWidth(appPathLabel, to: fields)
        autoStartButton.font = .systemFont(ofSize: 12)
        addFullWidth(formRow("", field: autoStartButton), to: fields)
        themeButton.font = .systemFont(ofSize: 12)
        themeButton.target = self
        themeButton.action = #selector(themeSelectionChanged)
        themeButton.toolTip = "适用于 Antigravity App。下次启动时加载界面主题、中文和会话统计。"
        addFullWidth(formRow("", field: themeButton), to: fields)
        themeRuntimeFields = verticalStack(spacing: 8)
        configureField(themeNodeField, placeholder: "留空自动检测 Node.js", accessibility: "Node.js 可执行文件路径")
        addFullWidth(formRow("Node.js", field: themeNodeField), to: themeRuntimeFields)
        let themeHint = NSTextField(wrappingLabelWithString:
            "需要 Node.js 22.13 或更新版本。需要手动指定时，填写 node 可执行文件的完整路径。")
        themeHint.font = .systemFont(ofSize: 11)
        themeHint.textColor = .secondaryLabelColor
        addFullWidth(themeHint, to: themeRuntimeFields)
        addFullWidth(themeRuntimeFields, to: fields)
        themeRuntimeFields.isHidden = true
        editableControls.append(contentsOf: [browseButton, autoStartButton, themeButton])
        return panel(fields)
    }

    private func makeStatusPanel() -> NSView {
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .labelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.isSelectable = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setupLabel.font = .systemFont(ofSize: 11)
        setupLabel.textColor = .secondaryLabelColor
        setupLabel.maximumNumberOfLines = 0

        statusImage.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        statusImage.contentTintColor = .secondaryLabelColor
        statusImage.widthAnchor.constraint(equalToConstant: 18).isActive = true
        statusImage.heightAnchor.constraint(equalToConstant: 18).isActive = true
        statusImage.setAccessibilityElement(false)
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.widthAnchor.constraint(equalToConstant: 18).isActive = true
        progressIndicator.heightAnchor.constraint(equalToConstant: 18).isActive = true
        progressIndicator.isHidden = true

        configureButton(installButton, title: "安装内核", action: #selector(installCore))
        installButton.setContentHuggingPriority(.required, for: .horizontal)
        configureButton(importCoreButton, title: "从文件安装…", action: #selector(importCore))
        importCoreButton.toolTip = "选择官方 \(CoreInstaller.asset)，安装前会校验 SHA-256"
        let coreActions = horizontalStack([installButton, importCoreButton], spacing: 8)
        coreActions.setContentHuggingPriority(.required, for: .horizontal)

        let header = horizontalStack([
            statusImage, progressIndicator, label("连接状态", size: 12, weight: .semibold),
            NSView(), coreActions
        ], spacing: 8)
        let text = verticalStack(spacing: 6)
        addFullWidth(statusLabel, to: text)
        addFullWidth(setupLabel, to: text)
        let root = verticalStack(spacing: 9)
        addFullWidth(header, to: root)
        addFullWidth(text, to: root)
        return panel(root)
    }

    private func makeActions() -> NSView {
        configureButton(saveButton, title: "保存设置", action: #selector(saveSettings))
        saveButton.toolTip = "保存设置；密码与订阅地址会存入钥匙串"
        configureButton(testButton, title: "测试连接", action: #selector(testConnection))
        testButton.toolTip = "获取订阅、启动本地代理并检查出口 IP，不会打开 Antigravity"
        configureButton(stopButton, title: "停止", action: #selector(stopConnection))
        stopButton.toolTip = "先请求退出 Antigravity，再停止代理"
        configureButton(launchButton, title: "启动 Antigravity", action: #selector(launchApplication))
        launchButton.toolTip = "让 Antigravity 通过本工具的本地代理启动"
        launchButton.bezelColor = .controlAccentColor
        for button in [saveButton, testButton, stopButton, launchButton] {
            button.controlSize = .large
        }
        return horizontalStack([saveButton, testButton, NSView(), stopButton, launchButton], spacing: 10)
    }

    private func populate(_ settings: ProxySettings, password: String) {
        sourceControl.selectedSegment = settings.useSubscription || settings.server.isEmpty ? 0 : 1
        subscriptionProxyButton.state = settings.subscriptionUseManualProxy ? .on : .off
        chainManualProxyButton.state = settings.chainManualProxy ? .on : .off
        useRelayURIButton.state = settings.useRelayURI ? .on : .off
        splitModelTrafficButton.state = settings.splitChainedModelTraffic ? .on : .off
        populateNodePopup(nodes: subscriptionCatalog?.nodes.map(\.name) ?? [], selected: settings.subscriptionNode)
        updateSourceFields()
        let index = ["http", "https", "socks5"].firstIndex(of: settings.proxyType) ?? 0
        protocolPopup.selectItem(at: index)
        serverField.stringValue = settings.server
        portField.stringValue = String(settings.port)
        usernameField.stringValue = settings.username
        passwordField.stringValue = password
        expectedExitIPField.stringValue = settings.expectedExitIP
        localPortField.stringValue = String(settings.localPort)
        directDomainsField.stringValue = settings.directDomains.joined(separator: ", ")
        directDomainSuffixesField.stringValue = settings.directDomainSuffixes.joined(separator: ", ")
        refreshApplicationPopup(selectedPath: settings.appPath)
        autoStartButton.state = settings.autoStart ? .on : .off
        themeButton.state = settings.themeEnabled ? .on : .off
        themeNodeField.stringValue = settings.themeNodePath
        if !settings.expectedExitIP.isEmpty || settings.localPort != 17898
            || !settings.directDomains.isEmpty || !settings.directDomainSuffixes.isEmpty {
            setAdvancedVisible(true)
        }
    }

    private func readSettings() throws -> ProxySettings {
        let trimming = CharacterSet.whitespacesAndNewlines
        let useSubscription = sourceControl.selectedSegment == 0
        let useDownloadProxy = subscriptionProxyButton.state == .on
        let chainManual = useSubscription && chainManualProxyButton.state == .on
        let useRelay = !useSubscription && useRelayURIButton.state == .on
        let needsManualProxy = !useSubscription || useDownloadProxy || chainManual
        let port = Int(portField.stringValue.trimmingCharacters(in: trimming)) ?? 0
        guard !needsManualProxy || (1...65535).contains(port) else {
            window.makeFirstResponder(portField)
            throw FormError.invalidPort("代理端口")
        }
        guard let localPort = Int(localPortField.stringValue.trimmingCharacters(in: trimming)), (1...65535).contains(localPort) else {
            setAdvancedVisible(true)
            window.makeFirstResponder(localPortField)
            throw FormError.invalidPort("本地端口")
        }
        var settings = ProxySettings()
        settings.useSubscription = useSubscription
        settings.subscriptionNode = subscriptionNodePopup.selectedItem?.representedObject as? String ?? ""
        settings.subscriptionUseManualProxy = useDownloadProxy
        settings.chainManualProxy = chainManual
        settings.useRelayURI = useRelay
        settings.splitChainedModelTraffic = (chainManual || useRelay) && splitModelTrafficButton.state == .on
        if useSubscription { try SettingsValidator.validateSubscriptionURL(subscriptionAddress) }
        if useRelay { _ = try VlessRelayURI(relayURIValue, localPort: localPort) }
        settings.proxyType = protocolPopup.selectedItem?.representedObject as? String ?? "http"
        settings.server = serverField.stringValue.trimmingCharacters(in: trimming)
        settings.port = port == 0 && !needsManualProxy ? 8080 : port
        settings.username = usernameField.stringValue
        settings.appPath = selectedApplicationPath()
        settings.expectedExitIP = expectedExitIPField.stringValue.trimmingCharacters(in: trimming)
        settings.localPort = localPort
        settings.autoStart = autoStartButton.state == .on
        settings.themeEnabled = themeButton.state == .on
        settings.themeNodePath = themeNodeField.stringValue.trimmingCharacters(in: trimming)
        let routing = try readRouting()
        settings.directDomains = routing.directDomains
        settings.directDomainSuffixes = routing.directDomainSuffixes
        try SettingsValidator.validate(settings)
        return settings
    }

    private func readRouting() throws -> RoutingPolicy {
        var settings = ProxySettings()
        let useSubscription = sourceControl.selectedSegment == 0
        settings.useSubscription = useSubscription
        settings.chainManualProxy = useSubscription && chainManualProxyButton.state == .on
        settings.useRelayURI = !useSubscription && useRelayURIButton.state == .on
        settings.splitChainedModelTraffic = splitModelTrafficButton.state == .on
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，"))
        settings.directDomains = directDomainsField.stringValue.components(separatedBy: separators).filter { !$0.isEmpty }
        settings.directDomainSuffixes = directDomainSuffixesField.stringValue.components(separatedBy: separators).filter { !$0.isEmpty }
        do {
            return try RoutingPolicy(settings: settings)
        } catch {
            setAdvancedVisible(true)
            throw error
        }
    }

    @objc private func applyRouting() {
        guard controller.canApplyRouting, window.makeFirstResponder(nil) else { return }
        do {
            let routing = try readRouting()
            controller.applyRouting(routing) {
                try SettingsStore.saveRouting(routing)
            }
        } catch {
            showError(error)
        }
    }

    @objc private func showSettings() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveSettings() {
        guard !isBusy, window.makeFirstResponder(nil) else { return }
        do {
            try SettingsStore.save(readSettings(), password: passwordField.stringValue,
                                   subscriptionURL: subscriptionAddress, relayURI: relayURIValue)
            setStatus("设置已保存，密码、订阅地址与中转链接保存在本机钥匙串。")
        } catch {
            showError(error)
        }
    }

    @objc private func testConnection() {
        prepareConnection(launch: false)
    }

    @objc private func launchApplication() {
        if controller.hasRunningApplication {
            controller.showApplication()
            return
        }
        prepareConnection(launch: true)
    }

    private func prepareConnection(launch: Bool) {
        guard !isBusy, window.makeFirstResponder(nil) else { return }
        do {
            let settings = try readSettings()
            let password = passwordField.stringValue
            let subscriptionURL = subscriptionAddress
            let relayURI = relayURIValue
            if launch {
                try LauncherController.validateApplicationForLaunch(at: URL(fileURLWithPath: settings.appPath))
                try SettingsStore.save(settings, password: password, subscriptionURL: subscriptionURL, relayURI: relayURI)
            }
            let connect: () -> Void = { [weak self] in
                guard let self else { return }
                if launch {
                    self.controller.start(settings: settings, password: password,
                                          subscriptionURL: subscriptionURL, relayURI: relayURI)
                } else {
                    self.controller.test(settings: settings, password: password,
                                         subscriptionURL: subscriptionURL, relayURI: relayURI)
                }
            }
            if coreIsInstalled { connect() }
            else { prepareCore(then: connect) }
        } catch {
            showError(error)
        }
    }

    @objc private func importProxy() {
        guard !isBusy, window.makeFirstResponder(nil) else { return }
        do {
            let proxy = try ProxyImport(NSPasteboard.general.string(forType: .string) ?? "")
            protocolPopup.selectItem(at: ["http", "https", "socks5"].firstIndex(of: proxy.proxyType) ?? 0)
            serverField.stringValue = proxy.server
            portField.stringValue = String(proxy.port)
            usernameField.stringValue = proxy.username
            passwordField.stringValue = proxy.password
            setStatus("已填入代理信息，点击“测试连接”检查；启动时会自动保存。")
        } catch {
            showError(error)
        }
    }

    private var subscriptionAddress: String {
        subscriptionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var relayURIValue: String {
        relayURIField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func importRelayURI() {
        guard !isBusy, window.makeFirstResponder(nil) else { return }
        do {
            let raw = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let localPort = Int(localPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 17898
            _ = try VlessRelayURI(raw, localPort: localPort)
            relayURIField.stringValue = raw
            useRelayURIButton.state = .on
            sourceControl.selectedSegment = 1
            updateSourceFields()
            setStatus("已填入加密中转链接，点击“测试连接”验证链式出口；启动时会自动存入钥匙串。")
        } catch {
            showError(error)
        }
    }

    @objc private func changeSource() {
        updateSourceFields()
    }

    private func updateSourceFields() {
        let usesSubscription = sourceControl.selectedSegment == 0
        let chainSub = usesSubscription && chainManualProxyButton.state == .on
        let useRelay = !usesSubscription && useRelayURIButton.state == .on
        subscriptionFields.isHidden = !usesSubscription
        manualFields.isHidden = usesSubscription && subscriptionProxyButton.state != .on && !chainSub
        useRelayURIButton.isHidden = usesSubscription
        relayURIRow.isHidden = !useRelay
        splitModelTrafficButton.isHidden = !(chainSub || useRelay)
    }

    @objc private func importSubscription() {
        guard !controllerBusy, !installingCore, window.makeFirstResponder(nil) else { return }
        do {
            let address = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try SettingsValidator.validateSubscriptionURL(address)
            subscriptionField.stringValue = address
            sourceControl.selectedSegment = 0
            if subscriptionCatalog?.urlFingerprint != SubscriptionCatalog.fingerprint(address) {
                populateNodePopup(nodes: [], selected: "")
            }
            updateSourceFields()
            setStatus("已填入订阅链接。点击“刷新节点”读取节点并快捷选择，或直接测试连接（会自动获取订阅）。")
        } catch {
            showError(error)
        }
    }

    /// Warm the subscription cache in the background so the first "测试连接" click is
    /// not spent waiting on the network. Failures are silent; a normal test reports them.
    private func prefetchSubscriptionIfNeeded(_ settings: ProxySettings) {
        guard settings.useSubscription else { return }
        let url = subscriptionAddress
        guard !url.isEmpty, (try? SettingsValidator.validateSubscriptionURL(url)) != nil else { return }
        if let cached = SubscriptionCache.load(for: url, maximumAge: SubscriptionCache.maximumAge),
           !cached.yaml.isEmpty {
            return
        }
        let proxy: SubscriptionDownloadProxy? = settings.subscriptionUseManualProxy
            ? SubscriptionDownloadProxy(settings: settings, password: passwordField.stringValue) : nil
        let startedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            let nodes = try? await Task.detached(priority: .utility) { () -> [SubscriptionNode] in
                let directory = AppPaths.runtimeDirectory
                    .appendingPathComponent("prefetch-" + UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let snapshot = try SubscriptionFetcher.fetch(
                    url: url, proxy: proxy, checkCancellation: {}, into: directory,
                    useCache: true, progress: { _ in })
                return snapshot.nodes
            }.value
            guard let nodes, !nodes.isEmpty, !self.isBusy, self.subscriptionAddress == url else { return }
            if let catalog = self.subscriptionCatalog, catalog.fetchedAt >= startedAt { return }
            self.storeSubscriptionNodes(nodes.map(\.name))
        }
    }

    /// True while a relay operation, a core install, or a node refresh owns the UI.
    private var isBusy: Bool { controllerBusy || installingCore || fetchingNodes }

    private func populateNodePopup(nodes: [String], selected: String) {
        subscriptionNodePopup.removeAllItems()
        subscriptionNodePopup.addItem(withTitle: "自动选择（延迟最低）")
        subscriptionNodePopup.lastItem?.representedObject = ""
        if nodes.isEmpty {
            subscriptionNodePopup.addItem(withTitle: "尚未读取节点，点“刷新节点”")
            subscriptionNodePopup.lastItem?.isEnabled = false
            subscriptionNodePopup.selectItem(at: 0)
            return
        }
        for name in nodes {
            subscriptionNodePopup.addItem(withTitle: name)
            subscriptionNodePopup.lastItem?.representedObject = name
        }
        if !selected.isEmpty,
           let index = subscriptionNodePopup.itemArray.firstIndex(where: {
               ($0.representedObject as? String) == selected
           }) {
            subscriptionNodePopup.selectItem(at: index)
        } else {
            subscriptionNodePopup.selectItem(at: 0)
        }
    }

    private func currentSelectedNode() -> String {
        subscriptionNodePopup.selectedItem?.representedObject as? String ?? ""
    }

    /// Uses the node list reported by a relay that already loaded the subscription.
    private func storeSubscriptionNodes(_ nodes: [String]) {
        guard !nodes.isEmpty else { return }
        let address = subscriptionAddress
        guard !address.isEmpty else { return }
        let catalog = SubscriptionCatalog(urlFingerprint: SubscriptionCatalog.fingerprint(address),
                                          nodes: nodes.map { SubscriptionNode(name: $0, type: "") },
                                          fetchedAt: Date())
        subscriptionCatalog = catalog
        try? SettingsStore.saveSubscriptionCatalog(catalog)
        let previous = currentSelectedNode()
        populateNodePopup(nodes: nodes, selected: nodes.contains(previous) ? previous : "")
    }

    private func applyCatalog(_ catalog: SubscriptionCatalog, usage: String) {
        subscriptionCatalog = catalog
        try? SettingsStore.saveSubscriptionCatalog(catalog)
        let previous = currentSelectedNode()
        let names = catalog.nodes.map(\.name)
        let kept = names.contains(previous) ? previous : ""
        populateNodePopup(nodes: names, selected: kept)
        var message = "已读取 \(names.count) 个节点"
        if !previous.isEmpty && kept.isEmpty { message += "；原选择已失效，已改为自动选择" }
        if !usage.isEmpty { message += " · " + usage }
        setStatus(message + "。可在“节点”中快捷切换。")
    }

    @objc private func refreshSubscriptionNodes() {
        guard !isBusy, window.makeFirstResponder(nil) else { return }
        guard sourceControl.selectedSegment == 0 else { return }
        let url = subscriptionAddress
        let proxy: SubscriptionDownloadProxy?
        do {
            try SettingsValidator.validateSubscriptionURL(url)
            if subscriptionProxyButton.state == .on {
                let trimming = CharacterSet.whitespacesAndNewlines
                let port = Int(portField.stringValue.trimmingCharacters(in: trimming)) ?? 0
                guard (1...65535).contains(port) else {
                    window.makeFirstResponder(portField)
                    throw FormError.invalidPort("代理端口")
                }
                var downloadSettings = ProxySettings()
                downloadSettings.useSubscription = false
                downloadSettings.proxyType = protocolPopup.selectedItem?.representedObject as? String ?? "http"
                downloadSettings.server = serverField.stringValue.trimmingCharacters(in: trimming)
                downloadSettings.port = port
                downloadSettings.username = usernameField.stringValue
                try SettingsValidator.validate(downloadSettings)
                proxy = SubscriptionDownloadProxy(settings: downloadSettings, password: passwordField.stringValue)
            } else {
                proxy = nil
            }
        } catch {
            showError(error)
            return
        }
        let cancellation = RuntimeCancellation()
        nodeRefreshCancellation = cancellation
        fetchingNodes = true
        setStatus("正在获取订阅节点…")
        updateControls()
        let reportProgress: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.fetchingNodes else { return }
                self.setStatus(message)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome: Result<(SubscriptionCatalog, String), Error>
            do {
                outcome = .success(try await Task.detached(priority: .userInitiated) { () -> (SubscriptionCatalog, String) in
                    let directory = AppPaths.runtimeDirectory
                        .appendingPathComponent("node-refresh-" + UUID().uuidString, isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let snapshot = try SubscriptionFetcher.fetch(
                        url: url, proxy: proxy,
                        checkCancellation: { try cancellation.check() },
                        into: directory, useCache: false, progress: { reportProgress($0) })
                    return (SubscriptionCatalog(urlFingerprint: SubscriptionCatalog.fingerprint(url),
                                                nodes: snapshot.nodes, fetchedAt: Date()),
                            SubscriptionUsage.summary(fromUserInfo: snapshot.userInfo))
                }.value)
            } catch {
                outcome = .failure(error)
            }
            self.fetchingNodes = false
            self.nodeRefreshCancellation = nil
            switch outcome {
            case .success(let (catalog, usage)):
                self.applyCatalog(catalog, usage: usage)
            case .failure(let error):
                if error.localizedDescription.contains("取消") {
                    self.setStatus("已取消读取订阅节点。")
                } else {
                    self.showError(error)
                }
            }
            self.updateControls()
        }
    }

    @objc private func stopConnection() {
        if fetchingNodes {
            nodeRefreshCancellation?.cancel()
            setStatus("正在取消读取订阅节点…")
            return
        }
        guard controllerBusy || controller.isRunning else { return }
        controller.stop()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // A newly installed or removed Antigravity edition should show up without relaunch.
        let current = detectedApplications.map { $0.url.path }
        let fresh = ApplicationLocator.installedApplications().map { $0.url.path }
        guard current != fresh else { return }
        refreshApplicationPopup(selectedPath: selectedApplicationPath())
        updateControls()
    }

    private func selectedApplicationPath() -> String {
        if let path = appPopup.selectedItem?.representedObject as? String, !path.isEmpty {
            return path
        }
        return customApplicationPath
    }

    private func refreshApplicationPopup(selectedPath: String) {
        detectedApplications = ApplicationLocator.installedApplications()
        let desired = selectedPath.isEmpty ? customApplicationPath : selectedPath
        appPopup.removeAllItems()
        for application in detectedApplications {
            appPopup.addItem(withTitle: application.displayName)
            appPopup.lastItem?.representedObject = application.url.path
            appPopup.lastItem?.toolTip = application.url.path
        }
        let knownPaths = Set(detectedApplications.map { $0.url.path })
        if !desired.isEmpty, !knownPaths.contains(desired) {
            customApplicationPath = desired
            let name = URL(fileURLWithPath: desired).deletingPathExtension().lastPathComponent
            appPopup.addItem(withTitle: "自定义：\(name)")
            appPopup.lastItem?.representedObject = desired
            appPopup.lastItem?.toolTip = desired
        }
        if appPopup.numberOfItems == 0 {
            appPopup.addItem(withTitle: "未找到 Antigravity，请点“选择…”")
            appPopup.lastItem?.isEnabled = false
        }
        if let index = appPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == desired }) {
            appPopup.selectItem(at: index)
        } else {
            appPopup.selectItem(at: 0)
        }
        if let path = appPopup.selectedItem?.representedObject as? String, knownPaths.contains(path) {
            customApplicationPath = ""
        }
        updateApplicationPathLabel()
    }

    private func updateApplicationPathLabel() {
        let path = selectedApplicationPath()
        appPathLabel.stringValue = path.isEmpty ? "未选择应用" : path
        appPathLabel.toolTip = path.isEmpty ? nil : path
    }

    @objc private func applicationSelectionChanged() {
        updateApplicationPathLabel()
        updateControls()
    }

    @objc private func themeSelectionChanged() {
        updateControls()
    }

    @objc private func browseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择 Antigravity"
        panel.message = "选择已安装的 Antigravity 应用。"
        panel.prompt = "选择应用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        let current = URL(fileURLWithPath: selectedApplicationPath())
        panel.directoryURL = current.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let identifier = Bundle(url: url)?.bundleIdentifier ?? ""
            guard ApplicationLocator.isSupported(identifier) else {
                self.showAlert(title: "不是 Antigravity 应用",
                               message: "请选择官方的 Antigravity 或 Antigravity IDE 应用；所选的应用标识为 \(identifier.isEmpty ? "未知" : identifier)。")
                return
            }
            self.customApplicationPath = url.path
            self.refreshApplicationPopup(selectedPath: url.path)
            self.updateControls()
        }
    }

    @objc private func toggleAdvanced() {
        setAdvancedVisible(advancedFields.isHidden)
    }

    private func setAdvancedVisible(_ visible: Bool) {
        advancedFields.isHidden = !visible
        advancedButton.image = NSImage(systemSymbolName: visible ? "chevron.down" : "chevron.forward", accessibilityDescription: nil)
        advancedButton.setAccessibilityLabel(visible ? "收起高级设置" : "展开高级设置")
    }

    @objc private func installCore() {
        prepareCore()
    }

    @objc private func importCore() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "从文件安装代理内核"
        panel.message = "请选择 Mihomo 官方发布的 \(CoreInstaller.asset)。只安装通过固定 SHA-256 校验的文件。"
        panel.prompt = "校验并安装"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.gzip]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.prepareCore(archive: url)
        }
    }

    private func prepareCore(archive: URL? = nil, then completion: (() -> Void)? = nil) {
        guard !installingCore, !controllerBusy else { return }
        installingCore = true
        setStatus("正在安装代理内核…")
        updateControls()
        installationTask = Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            defer {
                self.installingCore = false
                self.installationTask = nil
                self.updateControls()
                if self.terminationPending {
                    self.terminationPending = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                } else if succeeded {
                    completion?()
                }
            }
            do {
                try await CoreInstaller.ensureInstalled(archive: archive, progress: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.setStatus(message)
                    }
                })
                succeeded = true
                self.setStatus("代理内核已安装，可以测试连接。")
            } catch {
                self.setStatus("代理内核安装失败。")
                if !self.terminationPending {
                    self.showError(error)
                }
            }
        }
    }

    private var coreIsInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: AppPaths.mihomoExecutable.path)
    }

    private func updateControls() {
        let busy = isBusy
        for control in editableControls {
            control.isEnabled = !busy
        }
        let canApplyRouting = controller.canApplyRouting
        directDomainsField.isEnabled = !busy || canApplyRouting
        directDomainSuffixesField.isEnabled = !busy || canApplyRouting
        applyRoutingButton.isHidden = !controller.hasRunningApplication
        applyRoutingButton.isEnabled = canApplyRouting
        saveButton.isEnabled = !busy
        testButton.isEnabled = !busy
        let selectedAppPath = selectedApplicationPath()
        let supportsTheme = !selectedAppPath.isEmpty
            && ThemeSession.supportsApplication(at: URL(fileURLWithPath: selectedAppPath))
        themeButton.isEnabled = !busy && supportsTheme
        themeRuntimeFields.isHidden = !supportsTheme || themeButton.state != .on
        let selectedApp = detectedApplications.first(where: { $0.url.path == selectedAppPath })
        let appShortName = selectedApp?.name ?? "Antigravity"
        launchButton.title = controller.hasRunningApplication ? "显示 \(appShortName)" : "启动 \(appShortName)"
        autoStartButton.title = "打开本工具时自动启动 \(appShortName)"
        launchButton.isEnabled = controller.hasRunningApplication || !busy
        stopButton.title = fetchingNodes ? "取消刷新" : "停止"
        stopButton.isEnabled = controllerBusy || controller.isRunning || fetchingNodes
        installButton.isHidden = coreIsInstalled
        installButton.isEnabled = !busy
        importCoreButton.isHidden = coreIsInstalled
        importCoreButton.isEnabled = !busy
        let appFound = !selectedAppPath.isEmpty
            && ApplicationLocator.isApplication(at: URL(fileURLWithPath: selectedAppPath))
        setupLabel.stringValue = (coreIsInstalled ? "内核已安装" : "首次连接时自动安装内核")
            + " · " + (appFound ? "已找到 \(appShortName)" : "启动前请选择 Antigravity.app")
        let showProgress = installingCore || fetchingNodes || (controllerBusy && !controller.hasRunningApplication)
        progressIndicator.isHidden = !showProgress
        statusImage.isHidden = showProgress
        if showProgress {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        let statusText = statusLabel.stringValue
        let failed = statusText.contains("失败") || statusText.contains("无法")
            || statusText.contains("错误") || statusText.contains("不可用") || statusText.contains("取消")
        if controller.hasRunningApplication && !failed {
            statusImage.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            statusImage.contentTintColor = .systemGreen
        } else if failed {
            statusImage.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            statusImage.contentTintColor = .systemOrange
        } else {
            statusImage.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            statusImage.contentTintColor = .secondaryLabelColor
        }
        if !coreIsInstalled && !busy && statusLabel.stringValue == "先填写代理信息，再测试连接。" {
            setStatus("填写或导入代理后，直接测试或启动；首次连接会自动安装内核。")
        }
    }

    private func setStatus(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.setAccessibilityValue(message)
    }

    private func showError(_ error: Error) {
        setStatus(error.localizedDescription)
        showAlert(title: "暂时无法完成", message: error.localizedDescription)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func configureField(_ field: NSTextField, placeholder: String, accessibility: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.setAccessibilityLabel(accessibility)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        editableControls.append(field)
    }

    private func configureButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13)
        button.target = self
        button.action = action
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func horizontalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func formRow(_ title: String, field: NSView) -> NSStackView {
        let titleLabel = label(title, size: 12)
        titleLabel.widthAnchor.constraint(equalToConstant: 88).isActive = true
        return horizontalStack([titleLabel, field], spacing: 10)
    }

    private func panel(_ contents: NSView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 12
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        contents.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 18),
            contents.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -18),
            contents.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 16),
            contents.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -16)
        ])
        return box
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private enum FormError: LocalizedError {
    case invalidPort(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let name):
            return "\(name)应为 1 至 65535 之间的数字。"
        }
    }
}
