import Foundation
import CoreGraphics
import ImageIO

// Run with Models.swift, Languages.swift and Services.swift as an independent executable.
// The mock protocol never leaves this process or accesses the user's Keychain.
private final class MockProtocol: URLProtocol {
    static var inspect: ((URLRequest) throws -> (Int, String, String))?
    static var requests = 0
    static var failure: Error?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        do {
            guard let inspect = Self.inspect else { fatalError("Unexpected network request") }
            let (status, contentType, body) = try inspect(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            Self.failure = error
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private enum TestFailure: Error { case assertion(String) }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.assertion(message) }
}
private func payload(_ request: URLRequest) throws -> [String: Any] {
    let bytes: Data
    if let body = request.httpBody { bytes = body }
    else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        bytes = data
    } else { throw TestFailure.assertion("Missing request body") }
    return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
}

@main
private struct ServicesChecks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = TranslationService(session: session)
        var checks = 0
        let sample = "DAX translation test & 中文"
        let key = "synthetic-not-a-real-key"

        var config = ServiceConfig(name: "DeepL", kind: .deepL)
        MockProtocol.inspect = { request in
            let body = try payload(request)
            try require(request.url?.absoluteString == "https://api-free.deepl.com/v2/translate", "DeepL endpoint")
            try require(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key \(key)", "DeepL authentication")
            try require(body["target_lang"] as? String == "ZH-HANS", "DeepL Chinese mapping")
            try require(body["source_lang"] == nil, "Automatic source must be omitted")
            try require(body["text"] as? [String] == [sample], "Original text preserved")
            return (200, "application/json", "{\"translations\":[{\"text\":\"测试译文\",\"detected_source_language\":\"EN\"}]}")
        }
        let deepL = try await service.translate(sample, source: "auto", target: "zh-Hans", config: config, apiKey: key)
        try require(deepL.text == "测试译文" && deepL.detectedLanguage == "EN", "DeepL result")
        checks += 1

        config = ServiceConfig(name: "Google", kind: .google)
        MockProtocol.inspect = { request in
            let body = try payload(request)
            try require(request.url?.path == "/language/translate/v2", "Google endpoint")
            try require(request.value(forHTTPHeaderField: "X-Goog-Api-Key") == key, "Google authentication")
            try require(body["source"] as? String == "en" && body["target"] as? String == "zh-TW", "Google language mapping")
            return (200, "application/json", "{\"data\":{\"translations\":[{\"translatedText\":\"&quot;A &amp; B&#x21;&quot;\"}]}}")
        }
        let google = try await service.translate(sample, source: "en", target: "zh-Hant", config: config, apiKey: key)
        try require(google.text == "\"A & B!\"", "Google HTML entities")
        checks += 1

        config = ServiceConfig(name: "Compatible", kind: .openAI, endpoint: "https://api.example.test/v1", model: "translation-model", prompt: "Translate {{source}} to {{target}}.")
        MockProtocol.inspect = { request in
            let body = try payload(request)
            let messages = body["messages"] as! [[String: String]]
            try require(request.url?.path == "/v1/chat/completions", "OpenAI base endpoint normalization")
            try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)", "Bearer authentication")
            try require(messages.last?["content"] == sample, "User content separated from system prompt")
            try require(messages.first?["content"] == "Translate 英语 to 中文简体.", "Prompt language variables")
            try require(body["stream"] as? Bool == false, "Non-stream request")
            return (200, "application/json", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"完整译文\"}}]}")
        }
        let compatible = try await service.translate(sample, source: "en", target: "zh-Hans", config: config, apiKey: key)
        try require(compatible.text == "完整译文" && compatible.markdown, "OpenAI result")
        checks += 1

        config = ServiceConfig(name: "DeepSeek", kind: .openAI, endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-flash", options: ["thinking": "disabled", "maxTokens": "2048"])
        MockProtocol.inspect = { request in
            let body = try payload(request)
            try require(body["model"] as? String == "deepseek-flash", "Current DeepSeek model")
            try require((body["thinking"] as? [String: String])?["type"] == "disabled", "DeepSeek direct translation mode")
            try require(body["max_tokens"] as? Int == 2048, "Compatible provider output limit")
            return (200, "application/json", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"译文\"}}]}")
        }
        _ = try await service.translate(sample, source: "en", target: "zh-Hans", config: config, apiKey: key)
        checks += 1

        config = ServiceConfig(name: "OpenAI", kind: .openAI, model: "test-model", options: ["maxTokens": "2048"])
        MockProtocol.inspect = { request in
            let body = try payload(request)
            try require(body["max_completion_tokens"] as? Int == 2048 && body["max_tokens"] == nil, "Official OpenAI output limit field")
            return (200, "application/json", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"译文\"}}]}")
        }
        _ = try await service.translate(sample, source: "en", target: "zh-Hans", config: config, apiKey: key)
        checks += 1

        config = ServiceConfig(name: "Claude", kind: .claude, model: "claude-model")
        MockProtocol.inspect = { request in
            let body = try payload(request)
            try require(request.url?.path == "/v1/messages", "Claude endpoint")
            try require(request.value(forHTTPHeaderField: "x-api-key") == key, "Claude authentication")
            try require(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Claude version")
            try require(body["system"] is String && body["max_tokens"] is Int, "Claude payload")
            return (200, "application/json", "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"第一段\"},{\"type\":\"thinking\",\"thinking\":\"ignored\"},{\"type\":\"text\",\"text\":\"第二段\"}]}")
        }
        let claude = try await service.translate(sample, source: "auto", target: "zh-Hans", config: config, apiKey: key)
        try require(claude.text == "第一段\n第二段", "Claude content blocks")
        checks += 1

        config = ServiceConfig(name: "Ollama", kind: .ollama, model: "local-model")
        MockProtocol.inspect = { request in
            let body = try payload(request)
            try require(request.url?.absoluteString == "http://127.0.0.1:11434/api/chat", "Ollama endpoint")
            try require(request.value(forHTTPHeaderField: "Authorization") == nil, "Local model needs no embedded credential")
            try require(body["options"] is [String: Any], "Ollama options")
            return (200, "application/json", "{\"message\":{\"content\":\"本地译文\"},\"done\":true}")
        }
        let local = try await service.translate(sample, source: "auto", target: "zh-Hans", config: config, apiKey: nil)
        try require(local.text == "本地译文", "Ollama result")
        checks += 1

        // Each error must remain safe to display even if the server echoes the input or key.
        for status in [400, 401, 403, 404, 408, 413, 429, 456, 500, 529] {
            config = ServiceConfig(name: "DeepL", kind: .deepL)
            MockProtocol.inspect = { _ in (status, "application/json", "{\"message\":\"\(key) \(sample)\"}") }
            do {
                _ = try await service.translate(sample, source: "auto", target: "en", config: config, apiKey: key)
                throw TestFailure.assertion("HTTP failure was accepted")
            } catch let error as ServiceError {
                try require(!error.localizedDescription.contains(key) && !error.localizedDescription.contains(sample), "Sensitive error text")
            }
            checks += 1
        }

        let beforeValidation = MockProtocol.requests
        config = ServiceConfig(name: "DeepL", kind: .deepL)
        do {
            _ = try await service.translate(String(repeating: "中", count: 50_000), source: "auto", target: "en", config: config, apiKey: key)
            throw TestFailure.assertion("Oversized input accepted")
        } catch ServiceError.tooLarge {}
        do {
            _ = try await service.translate(" \n ", source: "auto", target: "en", config: config, apiKey: key)
            throw TestFailure.assertion("Whitespace input accepted")
        } catch ServiceError.emptyInput {}
        config = ServiceConfig(name: "Unsafe endpoint", kind: .openAI, endpoint: "http://example.test/v1", model: "model")
        do {
            _ = try await service.translate(sample, source: "auto", target: "en", config: config, apiKey: key)
            throw TestFailure.assertion("Remote plaintext endpoint accepted")
        } catch ServiceError.invalidEndpoint {}
        try require(MockProtocol.requests == beforeValidation, "Invalid input was transmitted")
        checks += 3

        config = ServiceConfig(name: "Compatible", kind: .openAI, model: "model")
        MockProtocol.inspect = { _ in (200, "application/json", "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"partial\"}}]}") }
        do {
            _ = try await service.translate(sample, source: "auto", target: "en", config: config, apiKey: key)
            throw TestFailure.assertion("Truncated response accepted")
        } catch ServiceError.incompleteResponse {}
        checks += 1

        MockProtocol.inspect = { request in
            let body = try payload(request)
            try require(body["stream"] as? Bool == true, "Streaming flag")
            return (200, "text/event-stream", "data: {\"choices\":[{\"delta\":{\"content\":\"Hello \"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"world\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
        }
        let streamed = try await service.translate(sample, source: "auto", target: "en", config: config, apiKey: key, onPartial: { _ in })
        try require(streamed.text == "Hello world", "Stream assembly")
        checks += 1

        config = ServiceConfig(name: "Claude", kind: .claude, model: "model")
        MockProtocol.inspect = { _ in
            (200, "text/event-stream", "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\",\"text\":\"Hello \"}}\n\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n")
        }
        let claudeStream = try await service.translate(sample, source: "auto", target: "en", config: config, apiKey: key, onPartial: { _ in })
        try require(claudeStream.text == "Hello world", "Claude stream content block and delta")
        checks += 1

        config = ServiceConfig(name: "Ollama", kind: .ollama, model: "model")
        MockProtocol.inspect = { _ in
            (200, "application/x-ndjson", "{\"message\":{\"content\":\"Hello \"},\"done\":false}\n{\"message\":{\"content\":\"world\"},\"done\":true}\n")
        }
        let ollamaStream = try await service.translate(sample, source: "auto", target: "en", config: config, apiKey: nil, onPartial: { _ in })
        try require(ollamaStream.text == "Hello world", "Ollama newline-delimited stream")
        checks += 1

        let speech = CloudSpeechService(session: session)
        MockProtocol.inspect = { request in
            let body = try payload(request)
            try require(request.url?.path == "/v1/text:synthesize", "Speech endpoint")
            try require((body["audioConfig"] as? [String: String])?["audioEncoding"] == "MP3", "Speech encoding")
            return (200, "application/json", "{\"audioContent\":\"AQID\"}")
        }
        let audio = try await speech.synthesize("Hello", language: "en-US", apiKey: key)
        try require(audio == Data([1, 2, 3]), "Speech data decoded")
        checks += 1

        let image = syntheticImage()
        let ocr = CloudOCRService(session: session)
        MockProtocol.inspect = { request in
            let body = try payload(request)
            try require(request.url?.path == "/v1/images:annotate", "OCR endpoint")
            let requestBody = (body["requests"] as! [[String: Any]])[0]
            try require((requestBody["image"] as? [String: String])?["content"] == image.base64EncodedString(), "OCR image payload")
            return (200, "application/json", "{\"responses\":[{\"fullTextAnnotation\":{\"text\":\"DAX\"},\"textAnnotations\":[{\"description\":\"DAX\"},{\"description\":\"DAX\",\"boundingPoly\":{\"vertices\":[{}, {\"x\":20}, {\"x\":20,\"y\":10}, {\"y\":10}]}}]}]}")
        }
        let recognized = try await ocr.recognize(imageData: image, apiKey: key, languages: ["en"])
        try require(recognized.text == "DAX" && recognized.regions.first?.bounds == CGRect(x: 0, y: 0, width: 20, height: 10), "OCR coordinates and omitted zero fields")
        checks += 1

        if let failure = MockProtocol.failure { throw failure }
        print("PASS: \(checks) service checks, including request contracts, streamed output, error privacy, input limits, OCR and speech")
    }

    static func syntheticImage() -> Data {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
