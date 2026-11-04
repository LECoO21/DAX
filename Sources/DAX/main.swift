import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    private var statusItem: NSStatusItem!
    private var resultPanel: NSPanel!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var hotkeys: [InputAction: HotKeyManager] = [:]
    private var issueItem: NSMenuItem!
    private var subscriptions = Set<AnyCancellable>()
    private var shortcutsPaused = false
    private var registeringShortcuts = false
    private var lastHotkeys: [String: HotkeyBinding] = [:]
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var adjustingSize = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let url = Bundle.main.url(forResource: "DAX", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let root = ProcessInfo.processInfo.environment["DAX_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent("DAX")
            model = try AppModel(root: root)
        } catch {
            let alert = NSAlert(); alert.messageText = "DAX 无法打开本地数据"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil); return
        }
        AppEnvironment.model = model
        resultPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        resultPanel.title = "DAX"
        resultPanel.titleVisibility = .hidden
        resultPanel.titlebarAppearsTransparent = true
        resultPanel.standardWindowButton(.closeButton)?.isHidden = true
        resultPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        resultPanel.standardWindowButton(.zoomButton)?.isHidden = true
        resultPanel.isMovableByWindowBackground = true
        resultPanel.isReleasedWhenClosed = false
        resultPanel.hidesOnDeactivate = false
        resultPanel.isFloatingPanel = true
        resultPanel.delegate = self
        resultPanel.minSize = NSSize(width: 360, height: 150)
        resultPanel.maxSize = NSSize(width: 1100, height: 1600)
        resultPanel.center()
        let resultHost = NSHostingView(rootView: AppSurface(model: model, system: model.systemQueue, onResize: { [weak self] height in self?.resize(height) }, openSettings: { [weak self] in self?.showSettings() }, openHistory: { [weak self] in self?.showHistory() }).ignoresSafeArea())
        resultHost.sizingOptions = []
        resultPanel.contentView = resultHost
        model.onShow = { [weak self] in self?.showResult() }
        model.onHide = { [weak self] in self?.resultPanel.orderOut(nil) }
        model.onIssue = { [weak self] message, _ in self?.showIssue(message) }
        model.onPreferencesChanged = { [weak self] in self?.applyPreferences() }
        model.onShortcutRecordingChanged = { [weak self] recording in
            guard let self else { return }
            self.shortcutsPaused = recording
            if recording { self.hotkeys.values.forEach { $0.unregister() } }
            else { self.registerHotkeys(force: true) }
        }
        configureMenu()
        configureMainMenu()
        configureKeyboard()
        applyPreferences()
        model.$busy.sink { [weak self] busy in
            self?.statusItem.button?.image = AppIcons.status
            self?.statusItem.button?.alphaValue = busy ? 0.6 : 1
            self?.statusItem.button?.toolTip = busy ? "DAX · 正在识别…" : "DAX"
        }.store(in: &subscriptions)
        if CommandLine.arguments.contains("--preview") {
            model.input = "根据开发手册开始开发，保留完整功能。"
            model.originalInput = model.input
            model.identifyLanguage()
            model.results = [ServiceResult(id: UUID(), name: "系统翻译 · 界面预览", state: .success, output: .init(text: "Development begins with the complete feature set.")), ServiceResult(id: UUID(), name: "服务状态预览", state: .failed, error: "此处展示独立的服务错误与重试入口。")]
            showResult()
        }
    }
    private func configureMainMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "DAX")
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DAX", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "打开图片进行 OCR…", action: #selector(importOCR), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "批量图片翻译…", action: #selector(importImageTranslation), keyEquivalent: "").target = self
        fileItem.submenu = fileMenu
        bar.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        bar.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "历史与收藏…", action: #selector(openHistory), keyEquivalent: "").target = self
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        bar.addItem(windowItem)
        NSApp.mainMenu = bar
    }
    private func configureKeyboard() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.model.pinned, !self.model.busy, self.resultPanel.isVisible,
                  self.resultPanel.attachedSheet == nil, self.model.systemQueue.request == nil else { return }
            self.resultPanel.orderOut(nil)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.resultPanel else { return event }
            if let editor = self.resultPanel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { self.resultPanel.performClose(nil); return nil }
            guard modifiers == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": self.resultPanel.performClose(nil)
            case "r": self.model.submit()
            case "s": if !self.model.input.isEmpty { self.model.toggleFavorite() }
            case "p": self.model.pinned.toggle(); self.applyPreferences()
            case "+", "=": self.model.preferences.fontSize = min(30, self.model.preferences.fontSize + 1)
            case "-": self.model.preferences.fontSize = max(10, self.model.preferences.fontSize - 1)
            case ",": self.showSettings()
            default: return event
            }
            return nil
        }
    }
    private func focusInput(in view: NSView?) {
        guard let view else { return }
        if let editor = view as? SubmitTextView { resultPanel.makeFirstResponder(editor); return }
        for child in view.subviews { focusInput(in: child) }
    }
    func windowDidResize(_ notification: Notification) {
        guard notification.object as AnyObject? === resultPanel, !adjustingSize, model.mode != .image else { return }
        model.panelWidth = resultPanel.frame.width
    }
    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = AppIcons.status
        statusItem.button?.toolTip = "DAX"
        let menu = NSMenu()
        for action in InputAction.allCases {
            let item = NSMenuItem(title: action.name, action: #selector(runAction(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开图片进行 OCR…", action: #selector(importOCR), keyEquivalent: "")
        menu.addItem(withTitle: "批量图片翻译…", action: #selector(importImageTranslation), keyEquivalent: "")
        menu.addItem(withTitle: "显示上次结果", action: #selector(showPrevious), keyEquivalent: "")
        menu.addItem(withTitle: "历史与收藏…", action: #selector(openHistory), keyEquivalent: "")
        menu.addItem(withTitle: "停止朗读", action: #selector(stopSpeech), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        issueItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        issueItem.isHidden = true
        issueItem.isEnabled = false
        menu.addItem(issueItem)
        menu.addItem(withTitle: "录屏权限设置…", action: #selector(screenPermission), keyEquivalent: "")
        menu.addItem(withTitle: "取词权限设置…", action: #selector(selectionPermission), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 DAX", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }
    private func registerHotkeys(force: Bool = false) {
        guard !shortcutsPaused, !registeringShortcuts, force || lastHotkeys != model.preferences.hotkeys else { return }
        registeringShortcuts = true
        defer { registeringShortcuts = false }
        var resolved = model.preferences.hotkeys
        for action in InputAction.allCases {
            let manager = hotkeys[action] ?? HotKeyManager()
            hotkeys[action] = manager
            manager.onTrigger = { [weak self] in self?.model.perform(action) }
            guard let binding = resolved[action.rawValue], binding.enabled else { manager.unregister(); continue }
            do { try manager.register(keyCode: binding.keyCode, modifiers: binding.modifiers) }
            catch {
                if let previous = lastHotkeys[action.rawValue], previous.enabled,
                   (try? manager.register(keyCode: previous.keyCode, modifiers: previous.modifiers)) != nil {
                    resolved[action.rawValue] = previous
                    showIssue("\(action.name)快捷键冲突，已恢复原快捷键。")
                } else {
                    resolved[action.rawValue]?.enabled = false
                    showIssue("\(action.name)快捷键无法注册，请在设置中修改；仍可使用菜单。")
                }
            }
        }
        lastHotkeys = resolved
        if model.preferences.hotkeys != resolved { model.preferences.hotkeys = resolved }
    }
    private func applyPreferences() {
        guard model != nil, resultPanel != nil, statusItem != nil else { return }
        registerHotkeys()
        resultPanel.level = model.pinned ? (model.preferences.enhancedPin ? .screenSaver : .floating) : .floating
        resultPanel.collectionBehavior = model.pinned && model.preferences.keepPinnedOnDesktop ? [.fullScreenAuxiliary] : [.canJoinAllSpaces, .fullScreenAuxiliary]
        switch model.preferences.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    private func resize(_ height: CGFloat) {
        guard resultPanel != nil, !adjustingSize else { return }
        adjustingSize = true
        defer { adjustingSize = false }
        let width: CGFloat = model.mode == .image ? 920 : model.panelWidth
        let screen = resultPanel.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0,y: 0,width: 1200,height: 900)
        let bounded = min(height, available.height * model.preferences.maxHeightFraction)
        let old = resultPanel.frame
        resultPanel.setFrame(NSRect(x: old.minX, y: old.maxY - bounded, width: min(width, available.width), height: bounded), display: true)
    }
    private func showResult() {
        guard resultPanel != nil, !model.busy else { return }
        if !model.isError {
            statusItem.button?.image = AppIcons.status
            statusItem.button?.alphaValue = 1
            statusItem.button?.toolTip = "DAX"
            issueItem.isHidden = true
        }
        if !model.pinned || !resultPanel.isVisible { positionPanel() }
        NSApp.activate(ignoringOtherApps: true)
        resultPanel.makeKeyAndOrderFront(nil)
        resultPanel.orderFrontRegardless()
        if model.input.isEmpty { focusInput(in: resultPanel.contentView) }
    }
    private func positionPanel() {
        let position = model.windowLocationOverride ?? model.preferences.panelPosition
        if position == "last" { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = resultPanel.frame.size
        var origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        switch position {
        case "cursor", "mouse": origin = CGPoint(x: NSEvent.mouseLocation.x + 12, y: NSEvent.mouseLocation.y - size.height - 12)
        case "statusIconBottom":
            if let button = statusItem.button, let window = button.window {
                let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
            }
        case "left": origin.x = visible.minX + 12
        case "right": origin.x = visible.maxX - size.width - 12
        default: break
        }
        origin.x = max(visible.minX, min(origin.x, visible.maxX-size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY-size.height))
        resultPanel.setFrameOrigin(origin)
    }
    private func showIssue(_ message: String) {
        statusItem.button?.image = AppIcons.attention
        statusItem.button?.alphaValue = 1
        statusItem.button?.toolTip = message
        issueItem.title = message
        issueItem.isHidden = false
    }
    func showSettings() {
        if model.systemQueue.request == nil { resultPanel.orderOut(nil) }
        if settingsWindow == nil {
            settingsWindow = NSWindow(contentRect: NSRect(x:0,y:0,width:800,height:600), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
            settingsWindow?.title = "DAX 设置"
            settingsWindow?.isReleasedWhenClosed = false
            settingsWindow?.contentView = NSHostingView(rootView: SettingsView(model: model))
            settingsWindow?.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func showHistory() {
        if model.systemQueue.request == nil { resultPanel.orderOut(nil) }
        if historyWindow == nil {
            historyWindow = NSWindow(contentRect: NSRect(x:0,y:0,width:740,height:540), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
            historyWindow?.title = "DAX 历史与收藏"
            historyWindow?.isReleasedWhenClosed = false
            historyWindow?.contentView = NSHostingView(rootView: HistoryView(model: model))
            historyWindow?.center()
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func runAction(_ sender: NSMenuItem) { if let value = sender.representedObject as? String, let action = InputAction(rawValue: value) { model.perform(action) } }
    @objc private func importOCR() { model.importImages(asTranslation: false) }
    @objc private func importImageTranslation() { model.importImages(asTranslation: true) }
    @objc private func showPrevious() { showResult() }
    @objc private func openSettings() { showSettings() }
    @objc private func openHistory() { showHistory() }
    @objc private func stopSpeech() { model.speech.stop(); model.audioPlayer?.stop(); model.speechTask?.cancel() }
    @objc private func screenPermission() { CaptureController.openPermissionSettings() }
    @objc private func selectionPermission() { SelectedTextReader.openPermissionSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) {
        if notification.object as AnyObject? === resultPanel {
            model.closeResult()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showResult(); return true }
    func application(_ application: NSApplication, open urls: [URL]) {
        let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !images.isEmpty { model.openImages(images, asTranslation: false) }
        for url in urls where !images.contains(url) {
            if url.scheme == "dax" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                switch url.host {
                case "translate": if let text = items.first(where: { $0.name == "text" })?.value { model.receive(text, origin: "url") }
                case "capture": model.perform(.captureTranslate)
                case "ocr": model.perform(.captureOCR)
                case "settings": showSettings()
                default: showIssue("无法识别这个 DAX 链接。")
                }
            } else if url.pathExtension.lowercased() == "bobplugin" {
                do { try model.installPlugin(from: url); showSettings() }
                catch { showIssue(error.localizedDescription) }

            }
        }
    }
}

struct AppSurface: View {
    @ObservedObject var model: AppModel
    @ObservedObject var system: SystemQueue
    var onResize: (CGFloat) -> Void
    var openSettings: () -> Void
    var openHistory: () -> Void
    var body: some View {
        ZStack {
            if model.mode == .image { ImageWorkspaceView(model: model, openSettings: openSettings).onAppear { onResize(620) } }
            else { ResultView(model: model, onResize: onResize, openSettings: openSettings, openHistory: openHistory) }
        }.dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter { $0.isFileURL && UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            guard !images.isEmpty else { return false }
            model.openImages(images, asTranslation: model.mode == .image)
            return true
        }.background(SystemTranslationBridge(request: system.request) { id, result in system.finish(id: id, result: result) })
    }
}


PluginWorker.runIfRequested()
if !OCRWorker.runIfRequested() {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
