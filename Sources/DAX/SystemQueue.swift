import Foundation
import SwiftUI

@MainActor
final class SystemQueue: ObservableObject {
    @Published var request: SystemTranslationRequest?
    private var pending: [(SystemTranslationRequest, CheckedContinuation<String, Error>)] = []
    private var active: CheckedContinuation<String, Error>?
    private var watchdog: Task<Void, Never>?

    func translate(_ text: String, source: String, target: String) async throws -> String {
        let item = SystemTranslationRequest(id: UUID(), text: text,
            sourceCode: source == "auto" ? nil : source, targetCode: target)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending.append((item, continuation))
                advance()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(item.id) }
        }
    }
    func finish(id: UUID, result: Result<String, Error>) {
        guard request?.id == id else { return }
        watchdog?.cancel()
        watchdog = nil
        let continuation = active
        active = nil
        request = nil
        continuation?.resume(with: result)
        advance()
    }
    private func cancel(_ id: UUID) {
        if request?.id == id { finish(id: id, result: .failure(CancellationError())); return }
        if let index = pending.firstIndex(where: { $0.0.id == id }) {
            let (_, continuation) = pending.remove(at: index)
            continuation.resume(throwing: CancellationError())
        }
    }
    private func advance() {
        guard active == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        active = next.1
        request = next.0
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(id: next.0.id, result: .failure(AppFailure("系统翻译等待超时，请下载语言资源或切换翻译服务后重试。")))
        }
    }
}
