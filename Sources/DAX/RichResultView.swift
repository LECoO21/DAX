import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

struct RichResultView: NSViewRepresentable {
    let output: TranslationOutput
    let fontSize: Double
    var pluginStore: PluginStore? = nil
    var onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight, pluginStore: pluginStore) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "height")
        configuration.setURLSchemeHandler(context.coordinator.images, forURLScheme: "bob-plugin")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        if let directory = Bundle.module.url(forResource: "Resources", withExtension: nil)?.appendingPathComponent("Web"),
           FileManager.default.fileExists(atPath: directory.appendingPathComponent("render.html").path) {
            let shell = directory.appendingPathComponent("render.html")
            context.coordinator.shellURL = shell
            view.loadFileURL(shell, allowingReadAccessTo: directory)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.images.store = pluginStore
        let payload = Payload(text: output.html ?? output.text,
                              format: output.html != nil ? "html" : (output.markdown ? "markdown" : "plain"),
                              fontSize: max(10, min(fontSize, 36)))
        context.coordinator.update(payload)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        coordinator.images.cancelAll()
    }

    struct Payload: Codable, Equatable {
        let text: String
        let format: String
        let fontSize: Double
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var shellURL: URL?
        var onHeight: (CGFloat) -> Void
        let images: PluginImageHandler
        private var payload: Payload?
        private var loaded = false

        init(onHeight: @escaping (CGFloat) -> Void, pluginStore: PluginStore?) {
            self.onHeight = onHeight
            images = PluginImageHandler(store: pluginStore)
        }

        func update(_ next: Payload) {
            guard payload != next else { return }
            payload = next
            render()
        }

        private func render() {
            guard loaded, let payload, let data = try? JSONEncoder().encode(payload) else { return }
            let json = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            webView?.evaluateJavaScript("void window.daxRender(\(json));")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            render()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let height = message.body as? Double, height.isFinite else { return }
            onHeight(CGFloat(max(24, min(height, 1600))))
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated {
                if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            if url.isFileURL, url.standardizedFileURL.path == shellURL?.standardizedFileURL.path {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

/// Exposes only image resources resolved through the plugin store's containment checks.
final class PluginImageHandler: NSObject, WKURLSchemeHandler {
    var store: PluginStore?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(store: PluginStore?) { self.store = store }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask)
        guard let store, let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        do {
            let file = try store.resourceURL(forBobPluginURL: url)
            guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
                  let mime = type.preferredMIMEType,
                  let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 16 * 1024 * 1024 else { throw URLError(.cannotDecodeContentData) }
            tasks[identifier] = Task { @MainActor [weak self] in
                do {
                    let data = try await Task.detached(priority: .utility) { try Data(contentsOf: file, options: .mappedIfSafe) }.value
                    guard !Task.isCancelled else { return }
                    urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                } catch {
                    if !Task.isCancelled { urlSchemeTask.didFailWithError(URLError(.cannotDecodeContentData)) }
                }
                self?.tasks[identifier] = nil
            }
        } catch {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
