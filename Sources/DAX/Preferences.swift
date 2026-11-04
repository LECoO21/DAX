import Foundation

struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled = true
}

enum InputAction: String, Codable, CaseIterable, Identifiable {
    case captureTranslate, selectedTranslate, inputTranslate, clipboardTranslate
    case captureOCR, continuousOCR, silentOCR, clipboardOCR, selectedSilent, fieldSilent, imageTranslate
    var id: String { rawValue }
    var name: String {
        switch self {
        case .captureTranslate: return "截图翻译"
        case .selectedTranslate: return "划词翻译"
        case .inputTranslate: return "输入翻译"
        case .clipboardTranslate: return "剪贴板翻译"
        case .captureOCR: return "截图 OCR"
        case .continuousOCR: return "连续截图 OCR"
        case .silentOCR: return "静默截图 OCR"
        case .clipboardOCR: return "剪贴板 OCR"
        case .selectedSilent: return "静默划词翻译"
        case .fieldSilent: return "静默输入框翻译"
        case .imageTranslate: return "原图翻译"
        }
    }
}

struct Preferences: Codable, Equatable {
    var primaryLanguage = "zh-Hans"
    var secondaryLanguage = "en"
    var source = "auto"
    var target = "auto"
    var autoTranslate = true
    var joinLines = false
    var smartParagraphs = false
    var splitIdentifiers = false
    var stripComments = false
    var repairHyphenation = false
    var copyOCR = false
    var copyFirstResult = false
    var autoSpeak = false
    var detectQR = true
    var ocrMode = "chineseEnglish"
    var ocrProvider = "local"
    var speechProvider = "local"
    var voiceID = ""
    var speechRate: Double = 0.5
    var fontSize: Double = 15
    var maxHeightFraction: Double = 0.8
    var inputMaxHeight: Double = 180
    var panelPosition = "center"
    var appearance = "system"
    var showInput = true
    var showLanguageBar = true
    var showCaptureButton = true
    var showClipboardButton = false
    var showHistoryButton = false
    var showFavoriteButton = true
    var showNamingCopies = false
    var renderMarkdown = true
    var keepPinnedOnDesktop = false
    var enhancedPin = false
    var historyLimit = 1000
    var saveHistory = true
    var launchAtLogin = false
    // Control+Option avoids Bob's Option and Shift+Option defaults.
    var shortcutDefaultsVersion = 2
    var hotkeys: [String: HotkeyBinding] = [
        "captureTranslate": .init(keyCode: 1, modifiers: 6144),
        "selectedTranslate": .init(keyCode: 2, modifiers: 6144),
        "inputTranslate": .init(keyCode: 0, modifiers: 6144)
    ]
}

struct AppConfiguration: Codable {
    var version = 1
    var preferences = Preferences()
    var services = [ServiceConfig(name: "系统翻译", kind: .system)]
}

struct ConfigurationStore {
    let root: URL
    var file: URL { root.appendingPathComponent("settings.json") }
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: file.path) else { return AppConfiguration() }
        return try decode(Data(contentsOf: file))
    }
    func decode(_ data: Data) throws -> AppConfiguration {
        guard var input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = input["version"] as? Int, version == 1 else {
            throw AppFailure("设置文件格式或版本不受支持。")
        }
        let baseline = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! [String: Any]
        let saved = input["preferences"] as? [String: Any] ?? [:]
        input["preferences"] = baseline.merging(saved) { _, saved in saved }
        var config = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: input))
        if (saved["shortcutDefaultsVersion"] as? Int ?? 1) < 2 {
            for (action, keyCode) in [("captureTranslate", UInt32(1)), ("selectedTranslate", UInt32(2)), ("inputTranslate", UInt32(0))] {
                guard var binding = config.preferences.hotkeys[action], binding.keyCode == keyCode, binding.modifiers == 2560 else { continue }
                let occupied = config.preferences.hotkeys.contains { other in
                    other.key != action && other.value.enabled && other.value.keyCode == keyCode && other.value.modifiers == 6144
                }
                if !occupied { binding.modifiers = 6144; config.preferences.hotkeys[action] = binding }
            }
            config.preferences.shortcutDefaultsVersion = 2
        }
        guard Set(config.services.map(\.id)).count == config.services.count,
              config.services.filter({ $0.kind == .system }).count <= 1 else {
            throw AppFailure("设置文件存在重复的服务。")
        }
        let p = config.preferences
        let languageCodes = Set(LanguageChoice.sources.map(\.id))
        guard (10...30).contains(p.fontSize), (0.3...1).contains(p.maxHeightFraction),
              (50...600).contains(p.inputMaxHeight), (0.1...0.8).contains(p.speechRate),
              (1...100_000).contains(p.historyLimit), languageCodes.contains(p.primaryLanguage),
              languageCodes.contains(p.secondaryLanguage), languageCodes.contains(p.source), languageCodes.contains(p.target),
              p.primaryLanguage != "auto", p.secondaryLanguage != "auto" else {
            throw AppFailure("设置文件包含超出支持范围的字体、窗口、语言或历史容量。")
        }
        let bindings = p.hotkeys.values.filter(\.enabled)
        guard Set(bindings.map { "\($0.keyCode)-\($0.modifiers)" }).count == bindings.count,
              bindings.allSatisfy({ $0.keyCode <= 127 && $0.modifiers & UInt32(256 | 2048 | 4096) != 0 }) else {
            throw AppFailure("设置文件的快捷键重复或缺少修饰键。")
        }
        return config
    }
    func save(_ config: AppConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: file, options: .atomic)
    }
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
