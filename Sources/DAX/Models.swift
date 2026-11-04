import Foundation

enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case system, dictionary, deepL, google, openAI, claude, ollama, plugin
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "系统翻译"
        case .dictionary: return "系统词典"
        case .deepL: return "DeepL"
        case .google: return "Google Cloud"
        case .openAI: return "OpenAI 兼容服务"
        case .claude: return "Claude"
        case .ollama: return "Ollama"
        case .plugin: return "Bob 插件"
        }
    }
}

struct ServiceConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: ServiceKind
    var enabled = true
    var endpoint = ""
    var model = ""
    var prompt = ""
    var pluginID: String? = nil
    var options: [String: String] = [:]
}

struct TranslationOutput: Codable, Equatable {
    var text: String
    var detectedLanguage: String? = nil
    var markdown = false
    var html: String? = nil
}

struct ServiceResult: Identifiable, Codable, Equatable {
    enum State: String, Codable { case idle, pending, running, success, failed, cancelled }
    var id: UUID
    var name: String
    var state: State
    var output: TranslationOutput? = nil
    var error: String? = nil
}

struct HistoryRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var createdAt = Date()
    var text: String
    var source: String
    var target: String
    var results: [ServiceResult]
    var favorite = false
    var origin = "text"
}

