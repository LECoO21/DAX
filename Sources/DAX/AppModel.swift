import AppKit
import SwiftUI
import NaturalLanguage
import ServiceManagement
import AVFoundation
import Translation
import CoreServices

@MainActor
final class AppModel: ObservableObject {
    enum Mode { case translate, ocr, image }
    @Published var preferences: Preferences { didSet { if !applyingConfiguration { saveConfiguration(); onPreferencesChanged?() } } }
    @Published var services: [ServiceConfig] { didSet { if !applyingConfiguration { cancelTranslation(clear: true); cancelImages(); saveConfiguration() } } }
    @Published var input = ""
    var originalInput = ""
    @Published var results: [ServiceResult] = []
    @Published var source = "auto"
    @Published var target = "auto"
    @Published var detectedLanguage = ""
    @Published var status = ""
    @Published var isError = false
    @Published var busy = false
    @Published var pinned = false
    @Published var panelWidth: CGFloat = 420
    @Published var inputVisibilityOverride: Bool?
    var windowLocationOverride: String?
    @Published var mode = Mode.translate
    @Published var favorite = false
    @Published var plugins: [InstalledPlugin] = []
    @Published var imageItems: [ImageItem] = []
    @Published var selectedImage: UUID?
    @Published var showOriginalImage = false
    @Published var historyRows: [HistoryRecord] = []
    @Published var notice = ""
    let systemQueue = SystemQueue()
    let speech = SpeechController()
    let root: URL
    let settingsStore: ConfigurationStore
    let history: HistoryStore
    let pluginStore: PluginStore
    let pluginRuntime = BobPluginRuntime()
    let translator = TranslationService()
    let capture = CaptureController()
    let ocr = OCRRecognizer()
    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
    var onIssue: ((String, Bool) -> Void)?
    var onPreferencesChanged: (() -> Void)?
    var onShortcutRecordingChanged: ((Bool) -> Void)?
    var selectionContext: SelectionContext?
    var queryID = UUID()
    var scriptRequestID: String?
    var captureRevision = UUID()
    var imageRevision = UUID()
    var serviceAttempts: [UUID: UUID] = [:]
    var currentRecord: HistoryRecord?
    var serviceTasks: [UUID: Task<Void, Never>] = [:]
    var captureTask: Task<Void, Never>?
    var editTask: Task<Void, Never>?
    var imageTask: Task<Void, Never>?
    var hasCopiedFirst = false
    private var applyingConfiguration = false
    var audioPlayer: AVAudioPlayer?
    var speechTask: Task<Void, Never>?

    init(root: URL) throws {
        self.root = root
        settingsStore = try ConfigurationStore(root: root)
        let configuration = try settingsStore.load()
        preferences = configuration.preferences
        services = configuration.services
        source = configuration.preferences.source
        target = configuration.preferences.target
        history = try HistoryStore(root: root)
        pluginStore = try PluginStore(rootURL: root.appendingPathComponent("Plugins"))
        plugins = try pluginStore.list()
        preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var detectedName: String { detectedLanguage.isEmpty ? "等待识别" : LanguageChoice.name(detectedLanguage) }
    var actualSource: String { source == "auto" ? detectedLanguage : source }
    var actualTarget: String { targetLanguage(for: actualSource) }
    func targetLanguage(for sourceLanguage: String) -> String {
        guard target == "auto" else { return target }
        let language = sourceLanguage.lowercased()
        let first = preferences.primaryLanguage.lowercased()
        let matches = language == first || (language.hasPrefix("zh") && first.hasPrefix("zh"))
        return matches ? preferences.secondaryLanguage : preferences.primaryLanguage
    }
    var canReplaceSelection: Bool { selectionContext?.canReplace == true }
    var activeServices: [ServiceConfig] {
        services.filter { config in config.enabled && (config.kind != .plugin || plugins.contains { $0.id == config.pluginID && $0.enabled }) }
    }
    var isTranslating: Bool { results.contains { $0.state == .running || $0.state == .pending } }

    func applyConfiguration(_ configuration: AppConfiguration) throws {
        try settingsStore.save(configuration)
        applyingConfiguration = true
        preferences = configuration.preferences
        services = configuration.services
        source = configuration.preferences.source
        target = configuration.preferences.target
        applyingConfiguration = false
        cancelTranslation(clear: true)
        cancelImages()
        if configuration.preferences.launchAtLogin != (SMAppService.mainApp.status == .enabled) {
            setLoginItem(configuration.preferences.launchAtLogin)
            if preferences.launchAtLogin != (SMAppService.mainApp.status == .enabled) {
                preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
        onPreferencesChanged?()
    }
    func saveConfiguration() {
        do { try settingsStore.save(AppConfiguration(preferences: preferences, services: services)) }
        catch { notice = "保存设置失败。\(error.localizedDescription)" }
    }
    func identifyLanguage() { detectedLanguage = detectLanguage(input) }
    func detectLanguage(_ text: String) -> String {
        let detector = NLLanguageRecognizer()
        detector.processString(text)
        let confidence = detector.languageHypotheses(withMaximum: 1).values.first ?? 0
        // Short OCR fragments are ambiguous. Keep confident third-language detections intact.
        if confidence < 0.6 {
            var hints: [NLLanguage: Double] = [:]
            hints[NLLanguage(rawValue: preferences.primaryLanguage)] = 0.5
            hints[NLLanguage(rawValue: preferences.secondaryLanguage)] = 0.5
            detector.reset()
            detector.languageHints = hints
            detector.processString(text)
        }
        let language = detector.dominantLanguage?.rawValue ?? ""
        if language.isEmpty, text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains(Int($0.value)) }) { return "zh-Hans" }
        return language
    }
    func normalize(_ text: String) -> String {
        TextNormalizer.apply(text, preferences: preferences)
    }
    func editInput(_ value: String) {
        scriptRequestID = nil
        cancelCapture()
        cancelTranslation(clear: true)
        currentRecord = nil
        favorite = false
        originalInput = value
        input = value
        identifyLanguage()
        editTask?.cancel()
        guard preferences.autoTranslate, mode == .translate, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        editTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            self?.submit(origin: "text")
        }
    }
    func languageChanged() {
        preferences.source = source
        preferences.target = target
        if !input.isEmpty, mode == .translate { submit(origin: "text") }
    }
    func swapLanguages() {
        let previousSource = actualSource.isEmpty ? preferences.primaryLanguage : actualSource
        source = actualTarget
        target = previousSource
        languageChanged()
    }
    func receive(_ text: String, origin: String, translate: Bool = true) {
        cancelCapture()
        selectionContext = nil
        editTask?.cancel()
        cancelTranslation(clear: true)
        speech.stop()
        speechTask?.cancel()
        audioPlayer?.stop()
        originalInput = text
        input = normalize(text)
        identifyLanguage()
        favorite = false
        currentRecord = nil
        mode = translate ? .translate : .ocr
        isError = false
        status = translate ? "" : "识别完成"
        if preferences.copyOCR && origin != "text" { copy(input) }
        onShow?()
        if translate { submit(origin: origin) }
    }
    func submit(origin: String = "text", silent: Bool = false) {
        editTask?.cancel()
        cancelTranslation(clear: true)
        input = normalize(input)
        identifyLanguage()
        guard !input.isEmpty else { return }
        let enabled = activeServices
        guard !enabled.isEmpty else { status = "请在服务设置中启用翻译服务。"; isError = true; return }
        mode = .translate
        let id = queryID
        hasCopiedFirst = false
        results = enabled.map { ServiceResult(id: $0.id, name: $0.name, state: $0.options["onDemand"] == "true" ? .idle : .running) }
        currentRecord = HistoryRecord(text: input, source: actualSource, target: actualTarget, results: results, origin: origin)
        favorite = false
        status = ""
        isError = false
        let text = input, originalText = originalInput, from = actualSource, to = actualTarget
        if preferences.autoSpeak { speak(text, language: from) }
        for config in enabled where config.options["onDemand"] != "true" {
            let attempt = UUID()
            serviceAttempts[config.id] = attempt
            serviceTasks[config.id] = Task { [weak self] in
                guard let self, !Task.isCancelled, self.queryID == id else { return }
                do {
                    if silent && config.kind == .system && from != to {
                        let availability = try await LanguageAvailability().status(for: text, to: Locale.Language(identifier: to))
                        guard availability == .installed else { throw AppFailure("静默系统翻译需要已下载的语言资源，请先完成一次普通翻译。") }
                    }
                    let output = try await self.performTranslation(text, originalText: originalText, source: from, target: to, config: config) { partial in
                        Task { @MainActor in
                            guard self.queryID == id, self.serviceAttempts[config.id] == attempt else { return }
                            self.updateResult(config.id, state: .running, output: .init(text: partial, markdown: true))
                        }
                    }
                    guard !Task.isCancelled, self.queryID == id, self.serviceAttempts[config.id] == attempt else { return }
                    self.serviceAttempts[config.id] = nil
                    self.updateResult(config.id, state: .success, output: output)
                    if !self.hasCopiedFirst {
                        self.hasCopiedFirst = true
                        if self.preferences.copyFirstResult { self.copy(output.text) }
                        if silent { self.replaceSelection(output.text) }
                    }
                    self.persistCurrentRecord()
                } catch {
                    guard !Task.isCancelled, self.queryID == id, self.serviceAttempts[config.id] == attempt else { return }
                    self.serviceAttempts[config.id] = nil
                    self.updateResult(config.id, state: .failed, error: error.localizedDescription)
                    if silent { self.onIssue?(error.localizedDescription, false) }
                    self.persistCurrentRecord()
                }
                self.serviceTasks[config.id] = nil
            }
        }
    }
    func performTranslation(_ text: String, originalText: String? = nil, source: String, target: String, config: ServiceConfig,
                            onPartial: (@Sendable (String) -> Void)? = nil) async throws -> TranslationOutput {
        switch config.kind {
        case .dictionary:
            guard let definition = DCSCopyTextDefinition(nil, text as CFString, CFRange(location: 0, length: (text as NSString).length))?.takeRetainedValue() else {
                throw AppFailure("系统词典没有找到该词条。可以修改原文，或在“词典”应用中启用对应语言的词典。")
            }
            return .init(text: definition as String, detectedLanguage: source)
        case .system:
            if source == target { return .init(text: text, detectedLanguage: source) }
            let translated = try await systemQueue.translate(text, source: source, target: target)
            return .init(text: translated, detectedLanguage: source)
        case .plugin:
            guard let plugin = plugins.first(where: { $0.id == config.pluginID && $0.enabled }) else { throw AppFailure("插件未安装或已停用。") }
            let options = try await pluginStore.loadOptions(for: plugin)
            let response = try await pluginRuntime.run(plugin: plugin, options: options, operation: "translate", query: [
                "text": text, "originalText": originalText ?? text,
                "detectFrom": bobLanguage(source.isEmpty ? preferences.primaryLanguage : source), "detectTo": bobLanguage(target),
                "from": bobLanguage(self.source), "to": bobLanguage(self.target)
            ], onStream: { value in onPartial?(value.text) })
            return .init(text: pluginText(response), detectedLanguage: source, markdown: response.format == "markdown", html: response.format == "html" ? response.text : nil)
        default:
            let key = try await CredentialStore.load(serviceID: config.id)
            return try await translator.translate(text, source: source, target: target, config: config, apiKey: key, onPartial: onPartial)
        }
    }
    func pluginText(_ response: PluginResponse) -> String { response.text }
    func bobLanguage(_ language: String) -> String {
        switch language { case "zh-Hans": return "zh-Hans"; case "zh-Hant": return "zh-Hant"; case "": return "auto"; default: return language }
    }
    func updateResult(_ id: UUID, state: ServiceResult.State, output: TranslationOutput? = nil, error: String? = nil) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].state = state
        results[index].output = output
        results[index].error = error
    }
    func retry(_ id: UUID) {
        guard let config = services.first(where: { $0.id == id }) else { return }
        serviceTasks[id]?.cancel()
        updateResult(id, state: .running)
        let attempt = UUID()
        serviceAttempts[id] = attempt
        let version = queryID, text = input, originalText = originalInput, from = actualSource, to = actualTarget
        serviceTasks[id] = Task { [weak self] in
            guard let self, !Task.isCancelled, self.queryID == version else { return }
            do {
                let output = try await self.performTranslation(text, originalText: originalText, source: from, target: to, config: config)
                guard !Task.isCancelled, self.queryID == version, self.serviceAttempts[id] == attempt else { return }
                self.updateResult(id, state: .success, output: output)
            } catch {
                guard !Task.isCancelled, self.queryID == version, self.serviceAttempts[id] == attempt else { return }
                self.updateResult(id, state: .failed, error: error.localizedDescription)
            }
            self.persistCurrentRecord()
        }
    }
    func cancelTranslation(clear: Bool = false) {
        queryID = UUID()
        serviceTasks.values.forEach { $0.cancel() }
        serviceTasks.removeAll()
        serviceAttempts.removeAll()
        for index in results.indices where results[index].state == .running || results[index].state == .pending {
            results[index].state = .cancelled
        }
        persistCurrentRecord()
        if clear {
            results = []
            currentRecord = nil
            favorite = false
        }
    }

    func persistCurrentRecord() {
        guard var record = currentRecord, preferences.saveHistory else { return }
        record.results = results
        record.favorite = favorite
        currentRecord = record
        do { try history.upsert(record); try history.prune(maxCount: preferences.historyLimit) }
        catch { notice = error.localizedDescription }
    }
    func toggleFavorite() {
        favorite.toggle()
        if currentRecord == nil { currentRecord = HistoryRecord(text: input, source: actualSource, target: actualTarget, results: results) }
        guard var record = currentRecord else { return }
        record.favorite = favorite
        currentRecord = record
        do {
            try history.upsert(record)
            try history.setFavorite(id: record.id, value: favorite)
        } catch { notice = error.localizedDescription }
    }
    func setHistoryFavorite(_ record: HistoryRecord, value: Bool) throws {
        try history.setFavorite(id: record.id, value: value)
        if currentRecord?.id == record.id { currentRecord?.favorite = value; favorite = value }
    }
    func deleteHistory(_ record: HistoryRecord) throws {
        try history.delete(id: record.id)
        if currentRecord?.id == record.id { currentRecord = nil; favorite = false }
    }
    func clearHistory() throws {
        try history.clear()
        if currentRecord?.favorite == false { currentRecord = nil; favorite = false }
    }
    func loadHistory(_ record: HistoryRecord) {
        scriptRequestID = nil
        cancelCapture()
        cancelImages()
        selectionContext = nil
        editTask?.cancel()
        cancelTranslation(clear: true)
        mode = .translate
        originalInput = record.text
        input = record.text
        source = record.source.isEmpty ? "auto" : record.source
        target = record.target
        identifyLanguage()
        results = record.results
        favorite = record.favorite
        currentRecord = record
        status = "历史记录"
        onShow?()
    }
    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func replaceSelection(_ text: String) {
        do {
            guard let selectionContext else { throw AppFailure("当前内容没有可以替换的取词目标。") }
            try selectionContext.replace(with: text)
            status = "已替换原文"
        }
        catch { fail(error) }
    }
    func fail(_ error: Error) {
        status = error.localizedDescription
        isError = true
        onIssue?(status, status.contains("权限"))
    }
    func closeResult() {
        cancelCapture()
        cancelImages()
        editTask?.cancel()
        cancelTranslation()
        speech.stop()
        speechTask?.cancel()
        audioPlayer?.stop()
    }
    func installPlugin(from url: URL) throws {
        let plugin = try pluginStore.install(from: url)
        refreshPlugins()
        if plugin.descriptor.category == "translate", !services.contains(where: { $0.pluginID == plugin.id }) {
            services.append(ServiceConfig(name: plugin.descriptor.name, kind: .plugin, enabled: plugin.enabled, pluginID: plugin.id))
        }
    }
    func refreshPlugins() {
        do { plugins = try pluginStore.list() } catch { notice = error.localizedDescription }
    }
    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            preferences.launchAtLogin = enabled
        } catch { notice = "登录启动设置失败。\(error.localizedDescription)" }
    }
    func speak(_ text: String, language: String) {
        speech.stop(); audioPlayer?.stop(); speechTask?.cancel()
        guard !text.isEmpty else { return }
        if preferences.speechProvider == "local" {
            speech.speak(text, language: language, voiceID: preferences.voiceID.isEmpty ? nil : preferences.voiceID, rate: Float(preferences.speechRate))
            return
        }
        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data: Data
                if self.preferences.speechProvider == "google", let config = self.services.first(where: { $0.kind == .google }),
                   let key = try await CredentialStore.load(serviceID: config.id) {
                    let voiceLanguage = language.hasPrefix("zh") ? "cmn-CN" : (language == "en" ? "en-US" : language)
                    data = try await CloudSpeechService().synthesize(text, language: voiceLanguage, voice: nil, apiKey: key)
                } else if let plugin = self.plugins.first(where: { $0.id == self.preferences.speechProvider && $0.enabled }) {
                    let response = try await self.pluginRuntime.run(plugin: plugin, options: await self.pluginStore.loadOptions(for: plugin), operation: "tts", query: ["text": text, "lang": self.bobLanguage(language)])
                    if let bytes = response.audioData { data = bytes }
                    else if let url = response.audioURL {
                        let (bytes, response) = try await URLSession.shared.data(from: url)
                        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw AppFailure("语音下载失败。") }
                        data = bytes
                    } else { throw AppFailure("语音插件未返回可播放的数据。") }
                } else { throw AppFailure("请配置语音服务。") }
                guard !Task.isCancelled else { return }
                self.audioPlayer = try AVAudioPlayer(data: data)
                self.audioPlayer?.play()
            } catch { if !Task.isCancelled { self.fail(error) } }
        }
    }
}

@MainActor enum AppEnvironment { static weak var model: AppModel? }
