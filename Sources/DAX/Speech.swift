import AppKit
import AVFoundation
import Combine

struct VoiceOption: Identifiable {
    let id: String
    let name: String
    let language: String
}

@MainActor
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var voices: [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().map { VoiceOption(id: $0.identifier, name: $0.name, language: $0.language) }
            .sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
    }

    func speak(_ text: String, language: String? = nil, voiceID: String? = nil, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else if let language {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = self?.synthesizer.isSpeaking ?? false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = self?.synthesizer.isSpeaking ?? false }
    }
}
