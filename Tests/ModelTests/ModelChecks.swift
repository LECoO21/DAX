import Foundation
import AppKit
import CoreText

@MainActor
final class ModelChecks {
    private var directories: [URL] = []
    func cleanup() { directories.forEach { try? FileManager.default.removeItem(at: $0) } }
    private func model() throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dax-model-check-" + UUID().uuidString)
        directories.append(root)
        let model = try AppModel(root: root)
        model.preferences.autoTranslate = false
        model.preferences.copyFirstResult = false
        return model
    }

    func testNormalizationIsOptInAndPreservesParagraphs() {
        var preferences = Preferences()
        let sample = "URLSession camelCase snake_case\n第二行"
        checkEqual(TextNormalizer.apply(sample, preferences: preferences), sample)
        preferences.splitIdentifiers = true
        checkEqual(TextNormalizer.apply(sample, preferences: preferences), "URL Session camel Case snake case\n第二行")
        preferences.repairHyphenation = true
        checkEqual(TextNormalizer.apply("multi-\nline and state-of-the-art", preferences: preferences), "multiline and state-of-the-art")
        preferences.smartParagraphs = true
        checkEqual(TextNormalizer.apply("This is\na sentence.\n\nNext paragraph.", preferences: preferences), "This is a sentence.\n\nNext paragraph.")
        checkEqual(TextNormalizer.apply("中文换\n行内容", preferences: preferences), "中文换行内容")
    }

    func testAmbiguousLanguageUsesPreferencesWithoutOverridingCertainLanguages() throws {
        let model = try model()
        checkEqual(model.detectLanguage("Hello worla"), "en")
        checkEqual(model.detectLanguage("Bonjour le monde"), "fr")
        checkEqual(model.detectLanguage("こんにちは世界"), "ja")
        checkEqual(model.detectLanguage("屏幕截图与文字识别测试"), "zh-Hans")
        checkEqual(model.targetLanguage(for: "zh-Hant"), "en")
        checkEqual(model.targetLanguage(for: "en"), "zh-Hans")
    }

    func testPluginReceivesOriginalTextAndSelectedLanguages() async throws {
        let model = try model()
        model.preferences.joinLines = true
        model.preferences.splitIdentifiers = true
        let directory = model.root.appendingPathComponent("query-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = ["identifier": "test.dax.query", "version": "1.0.0", "category": "translate", "name": "Query check"]
        try JSONSerialization.data(withJSONObject: info).write(to: directory.appendingPathComponent("info.json"))
        try """
        function supportLanguages() { return ['auto','en','zh-Hans','fr']; }
        function translate(query) {
          query.onCompletion({result:{toParagraphs:[JSON.stringify({
            text:query.text, originalText:query.originalText,
            from:query.from, to:query.to, detectFrom:query.detectFrom, detectTo:query.detectTo
          })]}});
        }
        """.write(to: directory.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        let plugin = try model.pluginStore.install(from: directory)
        model.refreshPlugins()
        let service = ServiceConfig(name: "Query check", kind: .plugin, pluginID: plugin.id)
        model.services = [service]
        model.source = "auto"
        model.target = "auto"
        let original = "  HelloWorld\nThis is a translation test.  "
        model.receive(original, origin: "clipboard")
        await model.serviceTasks[service.id]?.value
        var query = try pluginQuery(model)
        checkEqual(query["text"], "Hello World This is a translation test.")
        checkEqual(query["originalText"], original)
        checkEqual(query["from"], "auto")
        checkEqual(query["to"], "auto")
        checkEqual(query["detectFrom"], "en")
        checkEqual(query["detectTo"], "zh-Hans")

        model.retry(service.id)
        await model.serviceTasks[service.id]?.value
        query = try pluginQuery(model)
        checkEqual(query["originalText"], original)

        model.editInput("  NewText\nPlease translate.  ")
        model.source = "en"
        model.target = "fr"
        model.submit()
        await model.serviceTasks[service.id]?.value
        query = try pluginQuery(model)
        checkEqual(query["originalText"], "  NewText\nPlease translate.  ")
        checkEqual(query["from"], "en")
        checkEqual(query["to"], "fr")
        checkEqual(query["detectFrom"], "en")
        checkEqual(query["detectTo"], "fr")

        // Existing history contains the stored, preprocessed text only.
        let record = HistoryRecord(text: "Saved text", source: "en", target: "zh-Hans", results: [])
        model.loadHistory(record)
        model.submit()
        await model.serviceTasks[service.id]?.value
        query = try pluginQuery(model)
        checkEqual(query["originalText"], record.text)
        let imageResult = try await model.performTranslation("Image region", source: "en", target: "zh-Hans", config: service)
        let imageQuery = try JSONDecoder().decode([String: String].self, from: Data(imageResult.text.utf8))
        checkEqual(imageQuery["originalText"], "Image region")
    }

    private func pluginQuery(_ model: AppModel) throws -> [String: String] {
        let result = try unwrap(model.results.first)
        checkEqual(result.state, .success)
        return try JSONDecoder().decode([String: String].self, from: Data(try unwrap(result.output).text.utf8))
    }

    func testFullPluginLanguageCatalogSurvivesConfigurationImport() throws {
        let model = try model()
        let codes = LanguageChoice.sources.map(\.id)
        checkEqual(codes.count, 390)
        checkEqual(Set(codes).count, codes.count)
        checkEqual(LanguageChoice.sources.first?.id, "auto")
        checkEqual(LanguageChoice.targets.first?.name, "自动选择")
        checkEqual(LanguageChoice.name("yue"), "粤语")
        checkEqual(LanguageChoice.name("wyw"), "文言文")
        checkTrue(codes.contains("sr-Cyrl"))
        checkTrue(codes.contains("sr-Latn"))
        var preferences = Preferences()
        preferences.source = "pysx"
        preferences.target = "pt-br"
        preferences.primaryLanguage = "pt-pt"
        preferences.secondaryLanguage = "yue"
        let data = try JSONEncoder().encode(AppConfiguration(preferences: preferences, services: []))
        let restored = try model.settingsStore.decode(data)
        checkEqual(restored.preferences.source, "pysx")
        checkEqual(restored.preferences.target, "pt-br")
        checkEqual(restored.preferences.primaryLanguage, "pt-pt")
        checkEqual(restored.preferences.secondaryLanguage, "yue")
    }

    func testKeychainWaitKeepsMainActorResponsiveAndHonorsCancellation() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let operation = Task { @MainActor in
            try await KeychainAccess.run {
                checkFalse(Thread.isMainThread)
                started.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw AppFailure("Main actor did not resume") }
                return "synthetic credential"
            }
        }
        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + 2) == .success)
            }
        }
        checkTrue(didStart)
        operation.cancel()
        release.signal()
        do { _ = try await operation.value; failed("Cancelled keychain read was returned") }
        catch is CancellationError { }
        let value = try await KeychainAccess.run { "next operation" }
        checkEqual(value, "next operation")
    }

    func testSystemTranslationConfigurationInvalidatesAcrossIdle() throws {
        let state = TranslationBridgeState()
        state.update(nil)
        checkNil(state.configuration)
        let first = SystemTranslationRequest(id: UUID(), text: "First", sourceCode: "en", targetCode: "zh-Hans")
        state.update(first)
        let initial = try unwrap(state.configuration)
        state.update(nil)
        let idle = try unwrap(state.configuration)
        checkFalse(initial == idle)
        let second = SystemTranslationRequest(id: UUID(), text: "Second", sourceCode: "en", targetCode: "zh-Hans")
        state.update(second)
        let next = try unwrap(state.configuration)
        checkFalse(initial == next)
        checkFalse(idle == next)
        checkEqual(initial.source, next.source)
        checkEqual(initial.target, next.target)
    }

    func testOlderConfigurationGetsNewDefaults() throws {
        let model = try model()
        let json = try JSONSerialization.data(withJSONObject: ["version": 1, "preferences": ["fontSize": 17], "services": []])
        let config = try model.settingsStore.decode(json)
        checkEqual(config.preferences.fontSize, 17)
        checkFalse(config.preferences.splitIdentifiers)
        checkFalse(config.preferences.smartParagraphs)
    }

    func testLegacyShortcutsMigrateOnceWithoutReplacingCustomBindings() throws {
        let model = try model()
        let original: [String: Any] = ["version": 1, "services": [], "preferences": ["hotkeys": [
            "captureTranslate": ["keyCode": 1, "modifiers": 2560, "enabled": true],
            "selectedTranslate": ["keyCode": 2, "modifiers": 4352, "enabled": true]
        ]]]
        let migrated = try model.settingsStore.decode(JSONSerialization.data(withJSONObject: original))
        checkEqual(migrated.preferences.hotkeys["captureTranslate"]?.modifiers, 6144)
        checkEqual(migrated.preferences.hotkeys["selectedTranslate"]?.modifiers, 4352)
        var custom = migrated
        custom.preferences.hotkeys["captureTranslate"]?.modifiers = 2560
        let restored = try model.settingsStore.decode(JSONEncoder().encode(custom))
        checkEqual(restored.preferences.hotkeys["captureTranslate"]?.modifiers, 2560)
    }

    func testInvalidImportLeavesConfigurationUntouched() throws {
        let model = try model()
        let before = try Data(contentsOf: model.settingsStore.file)
        let json = try JSONSerialization.data(withJSONObject: ["version": 1, "preferences": ["fontSize": -1], "services": []])
        checkThrows(try model.settingsStore.decode(json))
        checkEqual(try Data(contentsOf: model.settingsStore.file), before)
    }

    func testStaleSystemResponseCannotReplaceNewInput() async throws {
        let model = try model()
        model.source = "en"
        model.target = "zh-Hans"
        model.receive("Old text", origin: "test")
        for _ in 0..<20 where model.systemQueue.request == nil { await Task.yield() }
        let oldID = try unwrap(model.systemQueue.request?.id)
        model.receive("New text", origin: "test", translate: false)
        model.systemQueue.finish(id: oldID, result: .success("旧内容"))
        for _ in 0..<10 { await Task.yield() }
        checkEqual(model.input, "New text")
        checkTrue(model.results.isEmpty)
        checkFalse(model.isTranslating)
        checkNil(model.systemQueue.request)
    }

    func testCancellationAdvancesSystemQueue() async throws {
        let queue = SystemQueue()
        let first = Task { try await queue.translate("one", source: "en", target: "zh-Hans") }
        for _ in 0..<20 where queue.request == nil { await Task.yield() }
        let second = Task { try await queue.translate("two", source: "en", target: "zh-Hans") }
        await Task.yield()
        first.cancel()
        do { _ = try await first.value; failed("Cancelled task returned success") } catch is CancellationError {} catch { failed("Unexpected error \(error)") }
        for _ in 0..<20 where queue.request?.text != "two" { await Task.yield() }
        checkEqual(queue.request?.text, "two")
        let secondID = try unwrap(queue.request?.id)
        queue.finish(id: secondID, result: .success("二"))
        let value = try await second.value
        checkEqual(value, "二")
        checkNil(queue.request)
    }

    func testScriptValidationAndStatus() throws {
        let model = try model()
        checkThrows(try ScriptRequest("[]"))
        checkThrows(try model.handleScript(ScriptRequest("{\"path\":\"translate\",\"body\":{\"action\":\"unknown\"}}")))
        checkThrows(try model.handleScript(ScriptRequest("{\"path\":\"translate\",\"body\":{\"action\":\"translateText\",\"text\":\" \"}}")))
        let status = try model.handleScript(ScriptRequest("{\"path\":\"status\"}"))
        checkEqual(status["busy"] as? Bool, false)
        checkEqual(status["text"] as? String, "")
    }

    func testImageRegionsUseCorrectLanguagesAndCompleteQueue() async throws {
        let model = try model()
        let context = CGContext(data: nil, width: 1000, height: 280, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 280))
        for (text, y) in [("HELLO WORLD", 190.0), ("屏幕文字识别", 65.0)] {
            let line = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 48, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 30, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
        let boundary = ImageLine(original: "edge", bounds: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        checkEqual(boundary.overlayBounds(imageSize: CGSize(width: 100, height: 100)), CGRect(x: 0, y: 0, width: 52, height: 52))
        let item = ImageItem(image: context.makeImage()!, name: "Fixture")
        model.imageItems = [item]
        model.startImageTranslation()
        for _ in 0..<1000 {
            if let request = model.systemQueue.request {
                model.systemQueue.finish(id: request.id, result: .success(request.targetCode + ": " + request.text))
            }
            if item.state == "已完成" || item.state == "失败" || item.state == "部分区域翻译失败" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        model.imageTask?.cancel()
        checkEqual(item.state, "已完成")
        checkTrue(item.lines.contains { $0.original.contains("HELLO") && $0.translated.hasPrefix("zh-Hans:") })
        checkTrue(item.lines.contains { $0.original.contains("屏幕") && $0.translated.hasPrefix("en:") })
    }

    func testServiceChangeCancelsImageWork() throws {
        let model = try model()
        let before = model.imageRevision
        model.imageTask = Task { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        let image = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let item = ImageItem(image: image, name: "Status fixture")
        item.state = "翻译中"
        model.imageItems = [item]
        checkEqual(try model.handleScript(ScriptRequest("{\"path\":\"status\"}"))["busy"] as? Bool, true)
        model.services = []
        checkEqual(try model.handleScript(ScriptRequest("{\"path\":\"status\"}"))["busy"] as? Bool, false)
        checkTrue(model.imageTask?.isCancelled == true)
        checkFalse(model.imageRevision == before)
    }

    func testDeletingActiveHistoryPreventsLateRecreation() throws {
        let model = try model()
        model.receive("Temporary record", origin: "test", translate: false)
        model.toggleFavorite()
        let record = try unwrap(model.currentRecord)
        try model.setHistoryFavorite(record, value: false)
        checkFalse(model.favorite)
        try model.deleteHistory(record)
        model.persistCurrentRecord()
        checkTrue(try model.history.list().isEmpty)
        checkNil(model.currentRecord)
    }

    func testCancellingQueryPersistsTerminalHistoryState() throws {
        let model = try model()
        let result = ServiceResult(id: UUID(), name: "Pending", state: .running)
        model.results = [result]
        model.currentRecord = HistoryRecord(text: "Query", source: "en", target: "zh-Hans", results: [result])
        model.cancelTranslation(clear: true)
        checkTrue(model.results.isEmpty)
        checkEqual(try model.history.list().first?.results.first?.state, .cancelled)
    }

    func testFavoriteSurvivesLateSnapshot() throws {
        let model = try model()
        model.receive("Keep me", origin: "test", translate: false)
        model.toggleFavorite()
        model.persistCurrentRecord()
        checkTrue(try unwrap(model.history.list().first).favorite)
        model.toggleFavorite()
        model.persistCurrentRecord()
        checkFalse(try unwrap(model.history.list().first).favorite)
    }
}

private func failed(_ message: String) -> Never { fatalError(message) }
private func checkEqual<T: Equatable>(_ left: T, _ right: T) { if left != right { failed("Expected \(right), got \(left)") } }
private func checkTrue(_ value: Bool) { if !value { failed("Expected true") } }
private func checkFalse(_ value: Bool) { checkTrue(!value) }
private func checkNil<T>(_ value: T?) { if value != nil { failed("Expected nil") } }
private func checkThrows<T>(_ expression: @autoclosure () throws -> T) { do { _ = try expression(); failed("Expected error") } catch {} }
private func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw AppFailure("Expected a value") }; return value }

@main
private struct ModelCheckRunner {
    @MainActor static func main() async throws {
        PluginWorker.runIfRequested()
        if OCRWorker.runIfRequested() { return }
        let tests = ModelChecks()
        defer { tests.cleanup() }
        tests.testNormalizationIsOptInAndPreservesParagraphs()
        try tests.testAmbiguousLanguageUsesPreferencesWithoutOverridingCertainLanguages()
        try await tests.testPluginReceivesOriginalTextAndSelectedLanguages()
        try tests.testFullPluginLanguageCatalogSurvivesConfigurationImport()
        try await tests.testKeychainWaitKeepsMainActorResponsiveAndHonorsCancellation()
        try tests.testSystemTranslationConfigurationInvalidatesAcrossIdle()
        try tests.testOlderConfigurationGetsNewDefaults()
        try tests.testLegacyShortcutsMigrateOnceWithoutReplacingCustomBindings()
        try tests.testInvalidImportLeavesConfigurationUntouched()
        try await tests.testStaleSystemResponseCannotReplaceNewInput()
        try await tests.testCancellationAdvancesSystemQueue()
        try tests.testScriptValidationAndStatus()
        try await tests.testImageRegionsUseCorrectLanguagesAndCompleteQueue()
        try tests.testServiceChangeCancelsImageWork()
        try tests.testDeletingActiveHistoryPreventsLateRecreation()
        try tests.testCancellingQueryPersistsTerminalHistoryState()
        try tests.testFavoriteSurvivesLateSnapshot()
        print("PASS 17 model checks: system session reuse, asynchronous keychain, language catalog, plugin query, normalization, migration, atomic import, stale response, queue cancellation, scripting and favorites")
    }
}
