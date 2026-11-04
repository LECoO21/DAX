import Foundation
import Translation

@main
struct SystemTranslationProbe {
    static func main() async {
        let availability = LanguageAvailability()
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "zh-Hans")
        let status = await availability.status(from: source, to: target)
        switch status {
        case .unsupported:
            print("UNAVAILABLE: System English → Chinese translation is unsupported")
        case .supported:
            print("NEEDS SETUP: Supported language pair requires a model download in the app's system prompt")
        case .installed:
            if #available(macOS 26.0, *) {
                do {
                    let session = TranslationSession(installedSource: source, target: target)
                    let response = try await session.translate("Hello, welcome to DAX.")
                    print("PASS installed system translation: \(response.targetText)")
                } catch {
                    print("FAILED installed system translation: \(error.localizedDescription)")
                }
            } else {
                print("NEEDS UI: Models installed; use the SwiftUI translationTask integration")
            }
        @unknown default:
            print("UNKNOWN language availability")
        }
    }
}
