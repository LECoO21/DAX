import AppKit
import WebKit

@MainActor
final class RendererCheck: NSObject, WKNavigationDelegate {
    let webView = WKWebView()
    var timeout: Task<Void, Never>?
    func start(_ file: URL) {
        webView.navigationDelegate = self
        webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        timeout = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if !Task.isCancelled { fail("Renderer timed out") }
        }
    }
    func fail(_ message: String) -> Never {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let script = #"""
                const markdown = '# Title\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet value = 1\n```\n\n$$x^2$$\n\n```mermaid\ngraph LR\nA-->B\n```';
                await window.daxRender({text: markdown, format: 'markdown', fontSize: 16});
                const result = {
                    heading: document.querySelector('h1')?.textContent === 'Title',
                    table: !!document.querySelector('table td'),
                    highlight: !!document.querySelector('pre code .hljs-keyword'),
                    math: !!document.querySelector('.katex'),
                    diagram: !!document.querySelector('.mermaid svg')
                };
                await window.daxRender({text:'<img src="file:///private/test"><script>window.compromised=true</script><p onclick="alert(1)">Safe</p>', format:'html', fontSize:15});
                result.sanitized = !window.compromised && !document.querySelector('#result script') && !document.querySelector('#result [onclick]') && !document.querySelector('#result [src^="file:"]');
                await window.daxRender({text:'<b>literal</b>',format:'plain',fontSize:15});
                result.plain = document.querySelector('#result').textContent === '<b>literal</b>' && !document.querySelector('#result b');
                return result;
                """#
                let values = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [String: Bool]
                guard let values, values.count == 7, values.values.allSatisfy({ $0 }) else { fail("Render assertions \(String(describing: values))") }
                timeout?.cancel()
                print("PASS 7 renderer checks: Markdown headings/tables, Swift highlighting, KaTeX, Mermaid, sanitized HTML and literal plain text")
                exit(0)
            } catch { fail(error.localizedDescription) }
        }
    }
}

@main
struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let check = RendererCheck()
        check.start(URL(fileURLWithPath: CommandLine.arguments[1]))
        app.run()
        withExtendedLifetime(check) {}
    }
}
