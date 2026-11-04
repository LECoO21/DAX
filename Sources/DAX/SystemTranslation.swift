import Foundation
import SwiftUI
import Translation

struct SystemTranslationRequest: Equatable {
    let id: UUID
    let text: String
    let sourceCode: String?
    let targetCode: String
}

/// Keeps Apple's translation session attached to a visible UI so model downloads can request consent.
@available(macOS 15.0, *)
struct SystemTranslationBridge: View {
    let request: SystemTranslationRequest?
    let onResult: (UUID, Result<String, Error>) -> Void
    @StateObject private var state = TranslationBridgeState()

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(state.configuration) { session in
                guard let request else { return }
                let identifier = request.id
                do {
                    let response = try await session.translate(request.text)
                    await MainActor.run { onResult(identifier, .success(response.targetText)) }
                } catch {
                    // The queue checks the request ID. A cancelled session must still finish
                    // its continuation, including when SwiftUI removes the hosting surface.
                    await MainActor.run { onResult(identifier, .failure(SystemTranslationFailure(error))) }
                }
            }
            .onChange(of: request, initial: true) { _, newRequest in
                state.update(newRequest)
            }
    }
}

private struct SystemTranslationFailure: LocalizedError {
    let message: String

    init(_ error: Error) {
        switch error {
        case TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing:
            message = "系统翻译暂不支持这个语言组合，请选择其他语言或翻译服务。"
        case TranslationError.unableToIdentifyLanguage:
            message = "系统翻译无法判断原文语言，请手动选择源语言。"
        case TranslationError.nothingToTranslate:
            message = "没有可翻译的文字。"
        default:
            message = "系统翻译未完成。首次使用可能需要在系统提示中下载语言资源，请确认后重试。"
        }
    }

    var errorDescription: String? { message }
}

@MainActor
final class TranslationBridgeState: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    func update(_ newRequest: SystemTranslationRequest?) {
        guard let newRequest else {
            // Keep the invalidation generation across idle periods. Recreating an
            // equal language configuration can be ignored by translationTask.
            configuration?.invalidate()
            return
        }
        let source = newRequest.sourceCode.flatMap { $0.isEmpty ? nil : Locale.Language(identifier: Self.systemCode($0)) }
        let target = Locale.Language(identifier: Self.systemCode(newRequest.targetCode))
        if var existing = configuration, existing.source == source, existing.target == target {
            existing.invalidate()
            configuration = existing
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private static func systemCode(_ code: String) -> String {
        switch code.lowercased() {
        case "zh", "zh-cn", "zh-hans": return "zh-Hans"
        case "zh-tw", "zh-hant": return "zh-Hant"
        case "en-us", "en-gb": return "en"
        default: return code
        }
    }
}
