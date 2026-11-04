import SwiftUI
import AppKit
import Carbon
import UniformTypeIdentifiers

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case translation = "翻译", ocr = "OCR", services = "服务", plugins = "插件", general = "通用", transfer = "导入导出"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .translation: return "character.bubble"
        case .ocr: return "viewfinder"
        case .services: return "square.stack.3d.up"
        case .plugins: return "puzzlepiece.extension"
        case .general: return "gearshape"
        case .transfer: return "arrow.up.arrow.down"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @LocalState private var category = SettingsCategory.translation
    @LocalState private var selectedService: UUID?
    @LocalState private var selectedPlugin: String?
    @LocalState private var keyEntry = ""
    @LocalState private var keyExists = false
    @LocalState private var credentialMutationInProgress = false
    @LocalState private var credentialStateRevision = UUID()
    @LocalState private var pluginOptions: [String: String] = [:]
    @LocalState private var message = ""
    @LocalState private var serviceToRemove: UUID?
    @LocalState private var pluginToRemove: String?
    @LocalState private var pendingUpdate: PluginUpdate?
    @LocalState private var pendingConfiguration: AppConfiguration?
    @LocalState private var updatingPlugin: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("DAX").font(.title2.bold()).padding(.horizontal, 14).padding(.vertical, 16)
                ForEach(SettingsCategory.allCases) { item in
                    Button {
                        category = item
                        message = ""
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(category == item ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.horizontal, 10).frame(width: 150)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(category.rawValue).font(.title2.bold()).padding(.horizontal, 22).padding(.vertical, 18)
                Divider()
                categoryContent.disabled(credentialMutationInProgress)
                if credentialMutationInProgress {
                    ProgressView("正在访问系统钥匙串…").controlSize(.small).padding(12)
                }
                if !message.isEmpty || !model.notice.isEmpty {
                    Divider()
                    HStack(alignment: .top) {
                        Text(message.isEmpty ? model.notice : message).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button { message = ""; model.notice = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    }.padding(12).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, idealWidth: 900, minHeight: 590, idealHeight: 680)
        .onAppear {
            model.refreshPlugins()
            selectedService = model.services.first?.id
            selectedPlugin = model.plugins.first?.id
            refreshCredentialState()
            loadPluginOptions()
        }
        .onChange(of: selectedService) { _, _ in keyEntry = ""; refreshCredentialState(); message = "" }
        .onChange(of: selectedPlugin) { _, _ in loadPluginOptions(); message = "" }
        .alert("删除翻译服务？", isPresented: Binding(get: { serviceToRemove != nil }, set: { if !$0 { serviceToRemove = nil } })) {
            Button("取消", role: .cancel) { serviceToRemove = nil }
            Button("删除", role: .destructive) { removeService() }
        } message: { Text("该服务配置及其保存的 API 密钥将被删除。") }
        .alert("卸载插件？", isPresented: Binding(get: { pluginToRemove != nil }, set: { if !$0 { pluginToRemove = nil } })) {
            Button("取消", role: .cancel) { pluginToRemove = nil }
            Button("卸载", role: .destructive) { removePlugin() }
        } message: { Text("插件、插件数据及其保存的选项将被移除。") }
        .alert("安装插件更新？", isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } })) {
            Button("取消", role: .cancel) { pendingUpdate = nil }
            Button("安装更新") { installUpdate() }
        } message: {
            if let update = pendingUpdate {
                Text("版本 \(update.version)\n\(update.downloadURL.host ?? "")\n\(update.description)")
            }
        }
        .alert("导入并替换当前设置？", isPresented: Binding(get: { pendingConfiguration != nil }, set: { if !$0 { pendingConfiguration = nil } })) {
            Button("取消", role: .cancel) { pendingConfiguration = nil }
            Button("导入") { applyImport() }
        } message: {
            Text("当前偏好和翻译服务列表将被文件中的配置替换。现有历史、收藏与已安装插件由各自的管理入口处理。导入后请核对服务密钥。")
        }
    }

    @ViewBuilder private var categoryContent: some View {
        switch category {
        case .translation: ScrollView { translationSettings.padding(22) }
        case .ocr: ScrollView { ocrSettings.padding(22) }
        case .services: servicesSettings
        case .plugins: pluginsSettings
        case .general: ScrollView { generalSettings.padding(22) }
        case .transfer: ScrollView { transferSettings.padding(22) }
        }
    }

    private var translationSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("语言与自动翻译") {
                VStack(alignment: .leading, spacing: 12) {
                    languagePicker("主要语言", selection: $model.preferences.primaryLanguage, allowAuto: false)
                    languagePicker("第二语言", selection: $model.preferences.secondaryLanguage, allowAuto: false)
                    Text("目标语言选择“自动选择”时，主要语言翻译为第二语言，其余语言翻译为主要语言。")
                        .font(.caption).foregroundStyle(.secondary)
                    languagePicker("默认源语言", selection: Binding(get: { model.preferences.source }, set: { model.preferences.source = $0; model.source = $0 }), allowAuto: true)
                    Picker("默认目标语言", selection: Binding(get: { model.preferences.target }, set: { model.preferences.target = $0; model.target = $0 })) {
                        ForEach(LanguageChoice.targets) { Text($0.name).tag($0.id) }
                    }
                    Toggle("编辑原文后自动翻译", isOn: $model.preferences.autoTranslate)
                    Toggle("自动复制首个成功译文", isOn: $model.preferences.copyFirstResult)
                    Toggle("翻译时自动朗读原文", isOn: $model.preferences.autoSpeak)
                }.padding(10)
            }
            GroupBox("文字处理") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("合并换行", isOn: $model.preferences.joinLines)
                    Toggle("智能整理段落（保留空行与列表）", isOn: $model.preferences.smartParagraphs)
                    Toggle("拆分驼峰与下划线单词", isOn: $model.preferences.splitIdentifiers)
                    Toggle("去除行首代码注释符", isOn: $model.preferences.stripComments)
                    Toggle("修复英文跨行连字符", isOn: $model.preferences.repairHyphenation)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("朗读") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("语音服务", selection: $model.preferences.speechProvider) {
                        Text("系统语音").tag("local")
                        Text("Google Cloud TTS").tag("google")
                        ForEach(model.plugins.filter { $0.enabled && $0.descriptor.category == "tts" }) { Text($0.descriptor.name).tag($0.id) }
                    }
                    if model.preferences.speechProvider == "local" {
                        Picker("声音", selection: $model.preferences.voiceID) {
                            Text("按语言自动选择").tag("")
                            ForEach(model.speech.voices) { Text("\($0.name) · \($0.language)").tag($0.id) }
                        }
                        HStack {
                            Text("语速")
                            Slider(value: $model.preferences.speechRate, in: 0.1...0.8, step: 0.05)
                            Text(model.preferences.speechRate, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 40)
                        }
                        HStack {
                            Button("试听") { model.speech.speak("你好，欢迎使用 DAX。", language: "zh-CN", voiceID: model.preferences.voiceID.isEmpty ? nil : model.preferences.voiceID, rate: Float(model.preferences.speechRate)) }
                            Button("停止") { model.speech.stop() }
                        }
                    } else if model.preferences.speechProvider == "google" {
                        Text("使用服务列表中的 Google Cloud 密钥，需要在该账户启用 Text-to-Speech。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("配置 Google Cloud") { selectGoogleService() }
                    } else {
                        Button("配置语音插件") { selectedPlugin = model.preferences.speechProvider; category = .plugins; loadPluginOptions() }
                    }
                }.padding(10)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ocrSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("文字识别") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("识别服务", selection: $model.preferences.ocrProvider) {
                        Text("Apple 本地识别").tag("local")
                        Text("Google Cloud Vision").tag("google")
                        ForEach(model.plugins.filter { $0.enabled && $0.descriptor.category == "ocr" }) { Text($0.descriptor.name).tag($0.id) }
                    }
                    if model.preferences.ocrProvider == "local" {
                        Picker("识别语言", selection: $model.preferences.ocrMode) {
                            Text("中文与英文").tag("chineseEnglish")
                            Text("系统扩展语言").tag("systemExtended")
                        }
                        Text("本地识别可离线使用。扩展模式的语言支持取决于系统版本与识别资源。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.preferences.ocrProvider == "google" {
                        Text("选中的图片会发送至 Google Cloud Vision，使用服务列表中的 Google Cloud 密钥。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("配置 Google Cloud") { selectGoogleService() }
                    } else {
                        Button("配置 OCR 插件") { selectedPlugin = model.preferences.ocrProvider; category = .plugins; loadPluginOptions() }
                    }
                    Toggle("识别条形码与二维码", isOn: $model.preferences.detectQR)
                    Toggle("识别后自动复制文字", isOn: $model.preferences.copyOCR)
                }.padding(10)
            }
            GroupBox("系统权限") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("区域截图需要屏幕录制权限，取词与替换文字需要辅助功能权限。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("屏幕录制设置") { CaptureController.openPermissionSettings() }
                        Button("辅助功能设置") { SelectedTextReader.openPermissionSettings() }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var servicesSettings: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedService) {
                    ForEach(model.services) { service in
                        HStack {
                            Toggle("", isOn: serviceBinding(service.id, \.enabled, fallback: service.enabled)).labelsHidden().toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(service.name).lineLimit(1)
                                Text(service.kind.label).font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3).tag(service.id)
                    }
                }.listStyle(.sidebar)
                Divider()
                HStack {
                    Menu {
                        ForEach(ServicePreset.allCases) { preset in
                            Button(preset.rawValue) { addService(preset) }
                                .disabled(preset == .system && model.services.contains { $0.kind == .system })
                        }
                    } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize()
                    Button { serviceToRemove = selectedService } label: { Image(systemName: "minus") }.disabled(selectedService == nil)
                    Spacer()
                    Button { moveService(-1) } label: { Image(systemName: "arrow.up") }.disabled(!canMoveService(-1))
                    Button { moveService(1) } label: { Image(systemName: "arrow.down") }.disabled(!canMoveService(1))
                }.buttonStyle(.borderless).padding(10)
            }.frame(width: 200)
            Divider()
            ScrollView {
                if let service = model.services.first(where: { $0.id == selectedService }) {
                    serviceEditor(service).padding(20)
                } else {
                    Text("添加一个翻译服务，或选择已有服务进行配置。")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
                }
            }.frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func serviceEditor(_ service: ServiceConfig) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("显示名称", text: serviceBinding(service.id, \.name, fallback: service.name)).textFieldStyle(.roundedBorder)
            Text(service.kind.label).font(.caption).foregroundStyle(.secondary)
            Toggle("按需翻译（点击结果卡时调用）", isOn: Binding(get: { service.options["onDemand"] == "true" }, set: { value in
                updateService(service.id) { $0.options["onDemand"] = value ? "true" : "false" }
            }))
            if service.kind == .system || service.kind == .dictionary {
                Text(service.kind == .system ? "使用 macOS 系统翻译。首次使用某个语言组合时，系统可能要求下载对应语言资源。" : "通过 macOS 已启用的词典查询单词或短语。可在系统“词典”应用中选择英汉等词典。")
                    .foregroundStyle(.secondary)
            } else if service.kind == .plugin {
                if let plugin = model.plugins.first(where: { $0.id == service.pluginID }) {
                    Text("插件 \(plugin.descriptor.name) · \(plugin.descriptor.version)")
                    Button("打开插件配置") { selectedPlugin = plugin.id; category = .plugins; loadPluginOptions() }
                } else { Text("该插件尚未安装，请在插件页面安装。 ").foregroundStyle(.orange) }
            } else {
                Text("服务地址").font(.headline)
                TextField("HTTPS 地址或本机服务地址", text: serviceBinding(service.id, \.endpoint, fallback: service.endpoint)).textFieldStyle(.roundedBorder)
                if service.kind == .deepL {
                    Picker("套餐", selection: Binding(get: { service.endpoint.contains("api-free") ? "free" : "pro" }, set: { value in
                        updateService(service.id) { $0.endpoint = value == "free" ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate" }
                    })) {
                        Text("API Free").tag("free")
                        Text("API Pro").tag("pro")
                    }.pickerStyle(.segmented)
                }
                if [.openAI, .claude, .ollama].contains(service.kind) {
                    TextField("模型名称", text: serviceBinding(service.id, \.model, fallback: service.model)).textFieldStyle(.roundedBorder)
                }
                Divider()
                Text("API 密钥").font(.headline)
                SecureField(keyExists ? "输入新密钥以替换" : (service.kind == .ollama ? "本机 Ollama 通常无需密钥" : "输入 API 密钥"), text: $keyEntry)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存密钥") { saveCredential(service.id) }.disabled(keyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if keyExists {
                        Button("授权读取密钥") { authorizeCredential(service.id) }
                        Button("删除密钥", role: .destructive) { deleteCredential(service.id) }
                    }
                }
                Text(keyExists ? "密钥已保存在系统钥匙串。首次授权凭据组件时，请在系统提示中选择“始终允许”，以保留重启后的访问权限。" : "尚未保存密钥。")
                    .font(.caption).foregroundStyle(.secondary)
                if service.kind != .ollama {
                    Text("启用此服务后，翻译文字会发送至该服务。账户额度与费用由服务商管理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if [.openAI, .claude, .ollama].contains(service.kind) {
                    Divider()
                    Text("翻译提示词").font(.headline)
                    TextEditor(text: serviceBinding(service.id, \.prompt, fallback: service.prompt)).font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 95).padding(4).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    Text("留空使用内置翻译指令。可使用 {{source}} 和 {{target}} 引用语言，原文作为独立消息提交。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("输出上限")
                        TextField("8192", text: serviceOption(service.id, key: "maxTokens")).textFieldStyle(.roundedBorder).frame(width: 100)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pluginsSettings: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedPlugin) {
                    ForEach(model.plugins) { plugin in
                        HStack {
                            Toggle("", isOn: Binding(get: { plugin.enabled }, set: { setPluginEnabled($0, plugin: plugin) })).labelsHidden().toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(plugin.descriptor.name).lineLimit(1)
                                Text("\(plugin.descriptor.category) · \(plugin.descriptor.version)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3).tag(plugin.id)
                    }
                }.listStyle(.sidebar)
                Divider()
                HStack {
                    Button("安装插件…") { installPlugin() }
                    Spacer()
                    Button { pluginToRemove = selectedPlugin } label: { Image(systemName: "minus") }.disabled(selectedPlugin == nil)
                }.controlSize(.small).padding(10)
            }.frame(width: 210)
            Divider()
            ScrollView {
                if let plugin = model.plugins.first(where: { $0.id == selectedPlugin }) {
                    pluginEditor(plugin).padding(20)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "puzzlepiece.extension").font(.largeTitle)
                        Text("安装 .bobplugin 文件或插件目录")
                        Button("选择插件…") { installPlugin() }
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 230)
                }
            }.frame(maxWidth: .infinity)
        }
    }

    private func pluginEditor(_ plugin: InstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plugin.descriptor.name).font(.headline)
            Text("\(plugin.descriptor.identifier)\n版本 \(plugin.descriptor.version)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let summary = plugin.descriptor.summary, !summary.isEmpty { Text(summary).font(.callout) }
            HStack {
                if let homepage = plugin.descriptor.homepage, let url = URL(string: homepage), ["https", "http"].contains(url.scheme ?? "") {
                    Link("插件主页", destination: url)
                }
                if plugin.descriptor.appcast != nil {
                    Button(updatingPlugin == plugin.id ? "检查中…" : "检查更新") { checkUpdate(plugin) }.disabled(updatingPlugin != nil)
                }
            }
            Divider()
            if let options = plugin.descriptor.options, !options.isEmpty {
                Button("授权读取插件配置") {
                    guard !credentialMutationInProgress else { return }
                    credentialMutationInProgress = true
                    message = "请完成系统对 DAXCredentials 的一次性授权，并选择“始终允许”。"
                    Task { @MainActor in
                        defer { credentialMutationInProgress = false }
                        do { try await PluginOptionsStore.authorize(pluginID: plugin.id); loadPluginOptions(); message = "插件配置访问已授权。" }
                        catch { message = error.localizedDescription }
                    }
                }
                ForEach(options) { option in pluginOptionEditor(option) }
                Button("保存插件配置") {
                    guard !credentialMutationInProgress else { return }
                    let options = pluginOptions
                    credentialMutationInProgress = true
                    Task { @MainActor in
                        defer { credentialMutationInProgress = false }
                        do { try await model.pluginStore.saveOptions(options, pluginID: plugin.id); message = "插件配置已保存。" }
                        catch { message = error.localizedDescription }
                    }
                }
            } else { Text("此插件没有配置项。 ").foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func pluginOptionEditor(_ option: PluginOption) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(option.title).font(.system(size: 13, weight: .medium))
            if option.type == "menu" {
                Picker(option.title, selection: optionBinding(option)) {
                    ForEach(Array((option.menuValues ?? []).enumerated()), id: \.offset) { _, value in Text(value.title).tag(value.value) }
                }.labelsHidden()
            } else if option.type == "text" {
                if option.isSecure {
                    SecureField(option.textConfig?.placeholderText ?? "", text: optionBinding(option)).textFieldStyle(.roundedBorder)
                } else if let height = option.textConfig?.height, height >= 60 {
                    TextEditor(text: optionBinding(option)).frame(height: min(180, height)).padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                } else {
                    TextField(option.textConfig?.placeholderText ?? "", text: optionBinding(option)).textFieldStyle(.roundedBorder)
                }
            } else {
                Text("插件使用了暂不支持的配置类型 \(option.type)。").foregroundStyle(.orange)
            }
            if let description = option.desc, !description.isEmpty { Text(description).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("快捷键") {
                VStack(spacing: 10) {
                    ForEach(InputAction.allCases) { action in
                        HStack {
                            Toggle(action.name, isOn: hotkeyEnabled(action)).toggleStyle(.checkbox)
                            Spacer()
                            ShortcutCaptureView(binding: model.preferences.hotkeys[action.rawValue], onRecording: { model.onShortcutRecordingChanged?($0) }) { binding in
                                if model.preferences.hotkeys.contains(where: { $0.key != action.rawValue && $0.value.enabled && $0.value.keyCode == binding.keyCode && $0.value.modifiers == binding.modifiers }) {
                                    message = "这个组合已用于另一项 DAX 操作，请重新选择。"
                                    return
                                }
                                model.preferences.hotkeys[action.rawValue] = binding
                            }.frame(width: 150, height: 26)
                            Button { model.preferences.hotkeys.removeValue(forKey: action.rawValue) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).disabled(model.preferences.hotkeys[action.rawValue] == nil).help("清除快捷键")
                        }
                    }
                    Text("点击组合键后录制。请包含 ⌘、⌥ 或 ⌃，按 Esc 取消。")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(10)
            }
            GroupBox("窗口与显示") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("外观", selection: $model.preferences.appearance) {
                        Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                    }
                    Picker("结果窗口位置", selection: $model.preferences.panelPosition) {
                        Text("屏幕中央").tag("center"); Text("鼠标附近").tag("mouse"); Text("上次位置").tag("last")
                    }
                    HStack { Text("文字大小"); Slider(value: $model.preferences.fontSize, in: 12...24, step: 1); Text("\(Int(model.preferences.fontSize))").monospacedDigit().frame(width: 30) }
                    HStack { Text("窗口最大高度"); Slider(value: $model.preferences.maxHeightFraction, in: 0.3...0.95, step: 0.05); Text("\(Int(model.preferences.maxHeightFraction * 100))%").monospacedDigit().frame(width: 40) }
                    HStack { Text("原文最大高度"); Slider(value: $model.preferences.inputMaxHeight, in: 60...500, step: 10); Text("\(Int(model.preferences.inputMaxHeight))").monospacedDigit().frame(width: 40) }
                    Toggle("默认显示原文", isOn: $model.preferences.showInput)
                    Toggle("显示语言选择栏", isOn: $model.preferences.showLanguageBar)
                    Toggle("显示截图按钮", isOn: $model.preferences.showCaptureButton)
                    Toggle("显示剪贴板按钮", isOn: $model.preferences.showClipboardButton)
                    Toggle("显示历史按钮", isOn: $model.preferences.showHistoryButton)
                    Toggle("显示收藏按钮", isOn: $model.preferences.showFavoriteButton)
                    Toggle("显示变量命名复制菜单", isOn: $model.preferences.showNamingCopies)
                    Toggle("渲染 Markdown 与富文本", isOn: $model.preferences.renderMarkdown)
                    Toggle("置顶后固定在当前桌面", isOn: $model.preferences.keepPinnedOnDesktop)
                    Toggle("增强置顶", isOn: $model.preferences.enhancedPin)
                }.padding(10)
            }
            GroupBox("历史与启动") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("保存翻译历史", isOn: $model.preferences.saveHistory)
                    Stepper("历史记录上限 \(model.preferences.historyLimit)", value: $model.preferences.historyLimit, in: 100...50_000, step: 100)
                        .disabled(!model.preferences.saveHistory)
                    Text("保存新记录时应用上限，收藏会保留。 ").font(.caption).foregroundStyle(.secondary)
                    Toggle("登录时启动 DAX", isOn: Binding(get: { model.preferences.launchAtLogin }, set: { model.setLoginItem($0) }))
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transferSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("偏好与服务配置") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("导出文件包含偏好、快捷键和翻译服务配置。服务密钥保存在系统钥匙串，插件选项通过插件页面管理。")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("导出设置 JSON…") { exportSettings() }
                        Button("导入设置 JSON…") { selectImport() }
                    }
                    Text("导入会替换当前偏好与服务列表，应用前会显示确认。 ").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("本机文件") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("在访达中打开 DAX 数据目录") { NSWorkspace.shared.open(model.root) }
                    Button("在访达中打开插件目录") { NSWorkspace.shared.open(model.pluginStore.rootURL) }
                    Text("历史与收藏的导入导出位于历史记录窗口。 ").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func languagePicker(_ title: String, selection: Binding<String>, allowAuto: Bool) -> some View {
        Picker(title, selection: selection) { ForEach(allowAuto ? LanguageChoice.sources : Array(LanguageChoice.sources.dropFirst())) { Text($0.name).tag($0.id) } }
    }
    private func serviceBinding<Value>(_ id: UUID, _ path: WritableKeyPath<ServiceConfig, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { model.services.first(where: { $0.id == id })?[keyPath: path] ?? fallback }, set: { value in updateService(id) { $0[keyPath: path] = value } })
    }
    private func updateService(_ id: UUID, change: (inout ServiceConfig) -> Void) {
        guard let index = model.services.firstIndex(where: { $0.id == id }) else { return }
        var updated = model.services
        change(&updated[index])
        model.services = updated
    }
    private func serviceOption(_ id: UUID, key: String) -> Binding<String> {
        Binding(get: { model.services.first(where: { $0.id == id })?.options[key] ?? "" }, set: { value in updateService(id) { $0.options[key] = value } })
    }
    private func addService(_ preset: ServicePreset) {
        let config = preset.configuration
        if config.kind == .system, model.services.contains(where: { $0.kind == .system }) { return }
        model.services.append(config)
        selectedService = config.id
    }
    private func canMoveService(_ delta: Int) -> Bool {
        guard let id = selectedService, let index = model.services.firstIndex(where: { $0.id == id }) else { return false }
        return model.services.indices.contains(index + delta)
    }
    private func moveService(_ delta: Int) {
        guard canMoveService(delta), let id = selectedService, let index = model.services.firstIndex(where: { $0.id == id }) else { return }
        model.services.swapAt(index, index + delta)
    }
    private func removeService() {
        guard !credentialMutationInProgress, let id = serviceToRemove else { return }
        serviceToRemove = nil
        credentialMutationInProgress = true
        credentialStateRevision = UUID()
        Task { @MainActor in
            defer { credentialMutationInProgress = false }
            do {
                try await CredentialStore.delete(serviceID: id)
                model.services.removeAll { $0.id == id }
                if selectedService == id { selectedService = model.services.first?.id }
                message = "服务已删除。"
            } catch { message = error.localizedDescription }
        }
    }
    private func refreshCredentialState() {
        keyExists = false
        credentialStateRevision = UUID()
        let revision = credentialStateRevision
        guard let id = selectedService else { return }
        Task { @MainActor in
            do {
                let exists = try await CredentialStore.exists(serviceID: id)
                guard selectedService == id, credentialStateRevision == revision else { return }
                keyExists = exists
            } catch {
                if selectedService == id, credentialStateRevision == revision { message = error.localizedDescription }
            }
        }
    }
    private func authorizeCredential(_ id: UUID) {
        guard !credentialMutationInProgress else { return }
        credentialMutationInProgress = true
        message = "请完成系统对 DAXCredentials 的一次性授权，并选择“始终允许”。"
        Task { @MainActor in
            defer { credentialMutationInProgress = false }
            do {
                try await CredentialStore.authorize(serviceID: id)
                message = "密钥访问已授权，后续翻译可直接读取。"
            } catch { message = error.localizedDescription }
        }
    }
    private func saveCredential(_ id: UUID) {
        guard !credentialMutationInProgress else { return }
        let submittedKey = keyEntry
        credentialMutationInProgress = true
        credentialStateRevision = UUID()
        Task { @MainActor in
            defer { credentialMutationInProgress = false }
            do {
                try await CredentialStore.save(submittedKey, serviceID: id)
                guard selectedService == id else { return }
                if keyEntry == submittedKey { keyEntry = "" }
                keyExists = true
                message = "密钥已保存。"
            } catch { message = error.localizedDescription }
        }
    }
    private func deleteCredential(_ id: UUID) {
        guard !credentialMutationInProgress else { return }
        credentialMutationInProgress = true
        credentialStateRevision = UUID()
        Task { @MainActor in
            defer { credentialMutationInProgress = false }
            do {
                try await CredentialStore.delete(serviceID: id)
                guard selectedService == id else { return }
                keyEntry = ""
                keyExists = false
                message = "密钥已删除。"
            } catch { message = error.localizedDescription }
        }
    }
    private func selectGoogleService() {
        if let current = model.services.first(where: { $0.kind == .google }) { selectedService = current.id }
        else { addService(.google) }
        category = .services
    }
    private func optionBinding(_ option: PluginOption) -> Binding<String> {
        Binding(get: { pluginOptions[option.identifier] ?? option.defaultValue ?? "" }, set: { pluginOptions[option.identifier] = $0 })
    }
    private func loadPluginOptions() {
        pluginOptions = [:]
        guard let plugin = model.plugins.first(where: { $0.id == selectedPlugin }) else { return }
        Task { @MainActor in
            do {
                let options = try await model.pluginStore.loadOptions(for: plugin)
                guard selectedPlugin == plugin.id else { return }
                // Preserve any edits made while the keychain read was pending.
                pluginOptions = options.merging(pluginOptions) { _, edited in edited }
            } catch {
                if selectedPlugin == plugin.id { message = error.localizedDescription }
            }
        }
    }
    private func installPlugin() {
        let panel = NSOpenPanel()
        panel.title = "安装 Bob 插件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "bobplugin") ?? .zip, .zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let plugin = try model.pluginStore.install(from: url)
            model.refreshPlugins()
            if plugin.descriptor.category == "translate", !model.services.contains(where: { $0.pluginID == plugin.id }) {
                model.services.append(ServiceConfig(name: plugin.descriptor.name, kind: .plugin, enabled: plugin.enabled, pluginID: plugin.id))
            }
            selectedPlugin = plugin.id
            loadPluginOptions()
            message = "已安装 \(plugin.descriptor.name)。"
        } catch { message = error.localizedDescription; model.refreshPlugins() }
    }
    private func setPluginEnabled(_ value: Bool, plugin: InstalledPlugin) {
        do {
            try model.pluginStore.setEnabled(value, id: plugin.id)
            model.refreshPlugins()
            if !value {
                model.cancelTranslation(clear: true)
                if model.preferences.ocrProvider == plugin.id { model.preferences.ocrProvider = "local" }
                if model.preferences.speechProvider == plugin.id { model.preferences.speechProvider = "local" }
            }
        } catch { message = error.localizedDescription }
    }
    private func removePlugin() {
        guard !credentialMutationInProgress, let id = pluginToRemove else { return }
        pluginToRemove = nil
        credentialMutationInProgress = true
        Task { @MainActor in
            defer { credentialMutationInProgress = false }
            do {
                model.cancelTranslation()
                model.cancelImages()
                try await model.pluginStore.remove(id: id)
                model.services.removeAll { $0.pluginID == id }
                if model.preferences.ocrProvider == id { model.preferences.ocrProvider = "local" }
                if model.preferences.speechProvider == id { model.preferences.speechProvider = "local" }
                model.refreshPlugins()
                if selectedPlugin == id { selectedPlugin = model.plugins.first?.id; loadPluginOptions() }
                message = "插件已卸载。"
            } catch { message = error.localizedDescription; model.refreshPlugins() }
        }
    }
    private func checkUpdate(_ plugin: InstalledPlugin) {
        updatingPlugin = plugin.id
        Task { @MainActor in
            defer { updatingPlugin = nil }
            do {
                if let update = try await model.pluginStore.checkUpdate(for: plugin) { pendingUpdate = update }
                else { message = "当前插件已是可用的最新版本。" }
            } catch { message = error.localizedDescription }
        }
    }
    private func installUpdate() {
        guard let update = pendingUpdate else { return }
        pendingUpdate = nil
        updatingPlugin = update.identifier
        Task { @MainActor in
            defer { updatingPlugin = nil }
            do {
                let plugin = try await model.pluginStore.install(update: update)
                model.refreshPlugins()
                selectedPlugin = plugin.id
                loadPluginOptions()
                message = "插件已更新至 \(plugin.descriptor.version)。"
            } catch { message = error.localizedDescription; model.refreshPlugins() }
        }
    }
    private func hotkeyEnabled(_ action: InputAction) -> Binding<Bool> {
        Binding(get: { model.preferences.hotkeys[action.rawValue]?.enabled ?? false }, set: { value in
            guard var binding = model.preferences.hotkeys[action.rawValue] else {
                message = "请先点击右侧“录制快捷键”设置组合。"
                return
            }
            binding.enabled = value
            model.preferences.hotkeys[action.rawValue] = binding
        })
    }
    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "DAX-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let configuration = AppConfiguration(preferences: model.preferences, services: model.services)
            try encoder.encode(configuration).write(to: url, options: .atomic)
            message = "设置已导出。"
        } catch { message = error.localizedDescription }
    }
    private func selectImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { pendingConfiguration = try model.settingsStore.decode(Data(contentsOf: url)) }
        catch { message = error.localizedDescription }
    }
    private func applyImport() {
        guard let configuration = pendingConfiguration else { return }
        pendingConfiguration = nil
        do {
            try model.applyConfiguration(configuration)
            selectedService = model.services.first?.id
            refreshCredentialState()
            message = "设置已导入，请核对服务密钥和快捷键。"
        } catch { message = error.localizedDescription }
    }
}

private enum ServicePreset: String, CaseIterable, Identifiable {
    case system = "系统翻译", dictionary = "系统词典", deepL = "DeepL", google = "Google Cloud", openAI = "OpenAI", claude = "Claude"
    case deepSeek = "DeepSeek", zhipu = "智谱", siliconFlow = "硅基流动", ollama = "Ollama"
    var id: String { rawValue }
    var configuration: ServiceConfig {
        switch self {
        case .system: return ServiceConfig(name: rawValue, kind: .system)
        case .dictionary: return ServiceConfig(name: rawValue, kind: .dictionary, options: ["onDemand": "true"])
        case .deepL: return ServiceConfig(name: rawValue, kind: .deepL, endpoint: "https://api-free.deepl.com/v2/translate")
        case .google: return ServiceConfig(name: rawValue, kind: .google, endpoint: "https://translation.googleapis.com/language/translate/v2")
        case .openAI: return ServiceConfig(name: rawValue, kind: .openAI, endpoint: "https://api.openai.com/v1/chat/completions")
        case .claude: return ServiceConfig(name: rawValue, kind: .claude, endpoint: "https://api.anthropic.com/v1/messages")
        case .deepSeek: return ServiceConfig(name: rawValue, kind: .openAI, endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-flash", options: ["thinking": "disabled"])
        case .zhipu: return ServiceConfig(name: rawValue, kind: .openAI, endpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        case .siliconFlow: return ServiceConfig(name: rawValue, kind: .openAI, endpoint: "https://api.siliconflow.cn/v1/chat/completions")
        case .ollama: return ServiceConfig(name: rawValue, kind: .ollama, endpoint: "http://127.0.0.1:11434/api/chat")
        }
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let binding: HotkeyBinding?
    let onRecording: (Bool) -> Void
    let onCapture: (HotkeyBinding) -> Void
    func makeNSView(context: Context) -> ShortcutCaptureButton {
        let view = ShortcutCaptureButton()
        view.bezelStyle = .rounded
        view.onCapture = onCapture
        view.onRecording = onRecording
        view.display(binding)
        return view
    }
    func updateNSView(_ view: ShortcutCaptureButton, context: Context) {
        view.onCapture = onCapture
        view.onRecording = onRecording
        view.display(binding)
    }
    static func dismantleNSView(_ view: ShortcutCaptureButton, coordinator: ()) { view.finishRecording() }
}

private final class ShortcutCaptureButton: NSButton {
    var onCapture: ((HotkeyBinding) -> Void)?
    var onRecording: ((Bool) -> Void)?
    private var recording = false
    private var normalTitle = "录制快捷键"
    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    func display(_ binding: HotkeyBinding?) {
        normalTitle = binding.map(Self.label) ?? "录制快捷键"
        if !recording { title = normalTitle }
    }
    @objc private func beginRecording() {
        recording = true
        title = "按下组合键…"
        onRecording?(true)
        window?.makeFirstResponder(self)
    }
    func finishRecording() {
        guard recording else { return }
        recording = false
        title = normalTitle
        onRecording?(false)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) { finishRecording(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            title = "需包含 ⌘、⌥ 或 ⌃"
            return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        onCapture?(binding)
        finishRecording()
    }
    override func resignFirstResponder() -> Bool { finishRecording(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() { if window == nil { finishRecording() } }
    private static func label(_ binding: HotkeyBinding) -> String {
        var prefix = ""
        if binding.modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if binding.modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if binding.modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if binding.modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        let keys: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"空格",50:"`",51:"⌫",123:"←",124:"→",125:"↓",126:"↑"]
        return prefix + " " + (keys[binding.keyCode] ?? "键码 \(binding.keyCode)")
    }
}
