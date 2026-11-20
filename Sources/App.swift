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
    private let appPathField = NSTextField()
    private let autoStartButton = NSButton(checkboxWithTitle: "打开本工具时自动启动 Antigravity", target: nil, action: nil)
    private let advancedButton = NSButton()
    private var advancedFields: NSStackView!
    private var editableControls: [NSControl] = []

    private let statusImage = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "先填写代理信息，再测试连接。")
    private let progressIndicator = NSProgressIndicator()
    private let installButton = NSButton()
    private let browseButton = NSButton()
    private let saveButton = NSButton()
    private let testButton = NSButton()
    private let launchButton = NSButton()
    private let stopButton = NSButton()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
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
            let settings = try SettingsStore.load()
            populate(settings, password: "")
            do {
                passwordField.stringValue = try SettingsStore.loadPassword()
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

        if let settings = loadedSettings, settings.autoStart {
            do {
                try SettingsValidator.validate(settings)
                if coreIsInstalled {
                    controller.start(settings: settings, password: passwordField.stringValue)
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
        guard controller.isRunning || controllerBusy else {
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
        controller.stop()
        return .terminateLater
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveSettings) {
            return !controllerBusy && !installingCore
        }
        if menuItem.action == #selector(testConnection) {
            return !controllerBusy && !installingCore && coreIsInstalled
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
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 704),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Antigravity ISP"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 610, height: 560)
        window.delegate = self
        window.setFrameAutosaveName("AntigravityISPSettings")
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
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        let content = verticalStack(spacing: 16)
        documentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])

        addFullWidth(makeHeader(), to: content)
        addFullWidth(makeProxyPanel(), to: content)
        addFullWidth(makeApplicationPanel(), to: content)
        addFullWidth(makeStatusPanel(), to: content)
        addFullWidth(makeActions(), to: content)
        let closeHint = label("关闭窗口会继续运行；停止时会先退出 Antigravity。", size: 11, color: .secondaryLabelColor)
        closeHint.alignment = .right
        addFullWidth(closeHint, to: content)
        content.setCustomSpacing(8, after: content.arrangedSubviews[content.arrangedSubviews.count - 2])
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
        protocolPopup.addItems(withTitles: ["HTTP", "HTTPS", "SOCKS5"])
        for (index, value) in ["http", "https", "socks5"].enumerated() {
            protocolPopup.item(at: index)?.representedObject = value
        }
        protocolPopup.widthAnchor.constraint(equalToConstant: 132).isActive = true
        protocolPopup.setAccessibilityLabel("代理协议")
        let protocolRow = horizontalStack([protocolPopup, NSView()], spacing: 0)
        addFullWidth(formRow("协议", field: protocolRow), to: fields)

        configureField(serverField, placeholder: "proxy.example.com", accessibility: "代理服务器")
        configureField(portField, placeholder: "8080", accessibility: "代理端口")
        portField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let portLabel = label("端口", size: 12, color: .secondaryLabelColor)
        portLabel.setContentHuggingPriority(.required, for: .horizontal)
        let serverAndPort = horizontalStack([serverField, portLabel, portField], spacing: 10)
        addFullWidth(formRow("服务器", field: serverAndPort), to: fields)
        configureField(usernameField, placeholder: "可选", accessibility: "代理用户名")
        addFullWidth(formRow("用户名", field: usernameField), to: fields)
        configureField(passwordField, placeholder: "可选", accessibility: "代理密码")
        addFullWidth(formRow("密码", field: passwordField), to: fields)
        addFullWidth(formRow("", field: label("密码保存在此 Mac 的钥匙串中。", size: 11, color: .secondaryLabelColor)), to: fields)

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
            label("出口 IP、端口与公司域名", size: 11, color: .secondaryLabelColor),
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
        configureField(directDomainSuffixesField, placeholder: "例如 corp.example.org（含子域名）", accessibility: "直连域名后缀")
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
        configureField(appPathField, placeholder: "/Applications/Antigravity.app", accessibility: "Antigravity 应用位置")
        appPathField.lineBreakMode = .byTruncatingMiddle
        configureButton(browseButton, title: "选择…", action: #selector(browseApplication))
        browseButton.setContentHuggingPriority(.required, for: .horizontal)
        addFullWidth(formRow("应用位置", field: horizontalStack([appPathField, browseButton], spacing: 8)), to: fields)
        autoStartButton.font = .systemFont(ofSize: 12)
        addFullWidth(formRow("", field: autoStartButton), to: fields)
        editableControls.append(contentsOf: [browseButton, autoStartButton])
        return panel(fields)
    }

    private func makeStatusPanel() -> NSView {
        let text = verticalStack(spacing: 5)
        addFullWidth(label("连接状态", size: 12, weight: .semibold), to: text)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addFullWidth(statusLabel, to: text)

        statusImage.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        statusImage.contentTintColor = .secondaryLabelColor
        statusImage.widthAnchor.constraint(equalToConstant: 20).isActive = true
        statusImage.heightAnchor.constraint(equalToConstant: 20).isActive = true
        statusImage.setAccessibilityElement(false)
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.widthAnchor.constraint(equalToConstant: 20).isActive = true
        progressIndicator.heightAnchor.constraint(equalToConstant: 20).isActive = true
        progressIndicator.isHidden = true

        configureButton(installButton, title: "安装代理内核", action: #selector(installCore))
        installButton.setContentHuggingPriority(.required, for: .horizontal)
        let row = horizontalStack([statusImage, progressIndicator, text, installButton], spacing: 10)
        return panel(row)
    }

    private func makeActions() -> NSView {
        configureButton(saveButton, title: "保存设置", action: #selector(saveSettings))
        configureButton(testButton, title: "测试连接", action: #selector(testConnection))
        configureButton(stopButton, title: "停止", action: #selector(stopConnection))
        stopButton.toolTip = "先请求退出 Antigravity，再停止代理"
        configureButton(launchButton, title: "启动 Antigravity", action: #selector(launchApplication))
        launchButton.bezelColor = .controlAccentColor
        return horizontalStack([saveButton, testButton, NSView(), stopButton, launchButton], spacing: 8)
    }

    private func populate(_ settings: ProxySettings, password: String) {
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
        appPathField.stringValue = settings.appPath
        autoStartButton.state = settings.autoStart ? .on : .off
        if !settings.expectedExitIP.isEmpty || settings.localPort != 17898
            || !settings.directDomains.isEmpty || !settings.directDomainSuffixes.isEmpty {
            setAdvancedVisible(true)
        }
    }

    private func readSettings() throws -> ProxySettings {
        let trimming = CharacterSet.whitespacesAndNewlines
        guard let port = Int(portField.stringValue.trimmingCharacters(in: trimming)), (1...65535).contains(port) else {
            window.makeFirstResponder(portField)
            throw FormError.invalidPort("代理端口")
        }
        guard let localPort = Int(localPortField.stringValue.trimmingCharacters(in: trimming)), (1...65535).contains(localPort) else {
            setAdvancedVisible(true)
            window.makeFirstResponder(localPortField)
            throw FormError.invalidPort("本地端口")
        }
        var settings = ProxySettings()
        settings.proxyType = protocolPopup.selectedItem?.representedObject as? String ?? "http"
        settings.server = serverField.stringValue.trimmingCharacters(in: trimming)
        settings.port = port
        settings.username = usernameField.stringValue
        settings.appPath = appPathField.stringValue.trimmingCharacters(in: trimming)
        settings.expectedExitIP = expectedExitIPField.stringValue.trimmingCharacters(in: trimming)
        settings.localPort = localPort
        settings.autoStart = autoStartButton.state == .on
        let routing = try readRouting()
        settings.directDomains = routing.directDomains
        settings.directDomainSuffixes = routing.directDomainSuffixes
        try SettingsValidator.validate(settings)
        return settings
    }

    private func readRouting() throws -> RoutingPolicy {
        var settings = ProxySettings()
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
        guard !controllerBusy, !installingCore else { return }
        do {
            try SettingsStore.save(readSettings(), password: passwordField.stringValue)
            setStatus(passwordField.stringValue.isEmpty ? "设置已保存。" : "设置已保存，密码已存入钥匙串。")
        } catch {
            showError(error)
        }
    }

    @objc private func testConnection() {
        guard !controllerBusy, !installingCore else { return }
        do {
            let settings = try readSettings()
            guard coreIsInstalled else {
                setStatus("请先安装代理内核，再测试连接。")
                return
            }
            controller.test(settings: settings, password: passwordField.stringValue)
        } catch {
            showError(error)
        }
    }

    @objc private func launchApplication() {
        if controller.hasRunningApplication {
            controller.showApplication()
            return
        }
        guard !controllerBusy, !installingCore else { return }
        do {
            let settings = try readSettings()
            guard coreIsInstalled else {
                setStatus("请先安装代理内核，再启动 Antigravity。")
                return
            }
            try SettingsStore.save(settings, password: passwordField.stringValue)
            controller.start(settings: settings, password: passwordField.stringValue)
        } catch {
            showError(error)
        }
    }

    @objc private func stopConnection() {
        guard controllerBusy || controller.isRunning else { return }
        controller.stop()
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
        let current = URL(fileURLWithPath: appPathField.stringValue)
        panel.directoryURL = current.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.appPathField.stringValue = url.path
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
        guard !installingCore, !controllerBusy else { return }
        installingCore = true
        setStatus("正在安装代理内核…")
        updateControls()
        installationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.installingCore = false
                self.installationTask = nil
                self.updateControls()
                if self.terminationPending {
                    self.terminationPending = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
            do {
                try await CoreInstaller.ensureInstalled(progress: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.setStatus(message)
                    }
                })
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
        let busy = controllerBusy || installingCore
        for control in editableControls {
            control.isEnabled = !busy
        }
        let canApplyRouting = controller.canApplyRouting
        directDomainsField.isEnabled = !busy || canApplyRouting
        directDomainSuffixesField.isEnabled = !busy || canApplyRouting
        applyRoutingButton.isHidden = !controller.hasRunningApplication
        applyRoutingButton.isEnabled = canApplyRouting
        saveButton.isEnabled = !busy
        testButton.isEnabled = !busy && coreIsInstalled
        launchButton.title = controller.hasRunningApplication ? "显示 Antigravity" : "启动 Antigravity"
        launchButton.isEnabled = controller.hasRunningApplication || (!busy && coreIsInstalled)
        stopButton.isEnabled = controllerBusy || controller.isRunning
        installButton.isHidden = coreIsInstalled
        installButton.isEnabled = !busy
        let showProgress = installingCore || (controllerBusy && !controller.hasRunningApplication)
        progressIndicator.isHidden = !showProgress
        statusImage.isHidden = showProgress
        if showProgress {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        statusImage.image = NSImage(systemSymbolName: controller.hasRunningApplication ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)
        statusImage.contentTintColor = controller.hasRunningApplication ? .systemGreen : .secondaryLabelColor
        if !coreIsInstalled && !busy && statusLabel.stringValue == "先填写代理信息，再测试连接。" {
            setStatus("首次使用请安装代理内核，再填写并测试代理。")
        }
    }

    private func setStatus(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.setAccessibilityValue(message)
    }

    private func showError(_ error: Error) {
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
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 25).isActive = true
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
        titleLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true
        return horizontalStack([titleLabel, field], spacing: 10)
    }

    private func panel(_ contents: NSView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        contents.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 16),
            contents.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -16),
            contents.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 15),
            contents.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -15)
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
