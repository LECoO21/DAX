import Foundation

@main
struct PluginRuntimeChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw PluginFailure(message: "CHECK FAILED: \(message)") }
    }

    static func main() async {
        PluginWorker.runIfRequested()
        do {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dax-plugin-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let store = try PluginStore(rootURL: temporary.appendingPathComponent("Plugins"))
            let runtime = BobPluginRuntime(executableURL: URL(fileURLWithPath: CommandLine.arguments[0]))
            let endpoint = ProcessInfo.processInfo.environment["DAX_TEST_ENDPOINT"] ?? "http://127.0.0.1:1"
            func fixture(_ category: String, _ code: String, suffix: String = "") throws -> InstalledPlugin {
                let directory = temporary.appendingPathComponent("fixture-\(category)\(suffix)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let info: [String: Any] = ["identifier": "test.dax.\(category)\(suffix)", "version": "1.0.0", "category": category, "name": "Contract test", "options": [["identifier": "endpoint", "type": "text", "title": "Endpoint"]]]
                try JSONSerialization.data(withJSONObject: info).write(to: directory.appendingPathComponent("info.json"))
                try code.write(to: directory.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
                try "exports.prefix = 'verified';".write(to: directory.appendingPathComponent("helper.js"), atomically: true, encoding: .utf8)
                return try store.install(from: directory)
            }
            let translate = try fixture("translate", """
            var helper = require('./helper');
            var crypto = require('crypto-js');
            function supportLanguages() { return ['auto', 'en', 'zh-Hans']; }
            async function translate(query) {
              var data = $data.fromUTF8('屏幕');
              if (data.toUTF8() !== '屏幕' || data.toHex() !== 'e5b18fe5b995') throw new Error('data contract');
              if (crypto.SHA256('abc').toString() !== 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') throw new Error('crypto contract');
              $file.mkdir('$sandbox/nested');
              if (!$file.write({path:'$sandbox/nested/test.txt',data:data})) throw new Error('write contract');
              if ($file.read('$sandbox/nested/test.txt').toUTF8() !== '屏幕') throw new Error('read contract');
              if ($file.write({path:'/main.js',data:data})) throw new Error('read only contract');
              if ($file.read('/../../etc/passwd') !== undefined) throw new Error('traversal contract');
              var response = await $http.post({url:$option.endpoint+'/json',header:{'Content-Type':'application/json'},body:{text:query.text}});
              if(response.response.statusCode !== 200 || response.data.echo !== query.text) throw new Error('http contract');
              query.onStream({content:{format:'plain',text:'partial'}});
              query.onCompletion({result:{content:{format:'markdown',text:helper.prefix+':'+response.data.echo},from:query.detectFrom,to:query.detectTo}});
            }
            """)
            let languages = try await runtime.run(plugin: translate, options: [:], operation: "languages", query: [:])
            try require((languages.raw["languages"] as? [String])?.contains("zh-Hans") == true, "supported languages")
            var streamed = ""
            let translated = try await runtime.run(plugin: translate, options: ["endpoint": endpoint], operation: "translate", query: ["text": "hello", "from": "auto", "to": "auto", "detectFrom": "en", "detectTo": "zh-Hans"]) { value in streamed = value.text }
            try require(translated.text == "verified:hello" && translated.format == "markdown", "translation result")
            try require(streamed == "partial", "translation streaming result")
            let streamPlugin = try fixture("translate", """
            function translate(query, completion) {
              var accumulated = '';
              $http.streamRequest({url:$option.endpoint+'/stream',method:'GET',cancelSignal:query.cancelSignal,streamHandler:function(part) { accumulated += part.text; },handler:function(response) {
                if(response.error) completion({error:response.error});
                else completion({result:{toParagraphs:[accumulated]}});
              }});
            }
            """, suffix: "stream")
            let stream = try await runtime.run(plugin: streamPlugin, options: ["endpoint": endpoint], operation: "translate", query: [:])
            try require(stream.text.contains("你好") && stream.text.contains("世界"), "HTTP split UTF-8 streaming")
            let ocr = try fixture("ocr", """
            function supportLanguages() { return ['auto','en']; }
            function supportBoundingBox() { return true; }
            function ocr(query, completion) {
              if (!$data.isData(query.image) || query.image.toUTF8() !== 'image-fixture') throw new Error('image contract');
              completion({result:{from:'en',regionInfos:[{paragraphInfos:[{texts:[{text:'OCR fixture',boundingBox:{points:[{x:0,y:0},{x:1,y:0},{x:0,y:1},{x:1,y:1}]}}]}]}]}});
            }
            """)
            let recognized = try await runtime.run(plugin: ocr, options: [:], operation: "ocr", query: ["image": ["__daxData": Data("image-fixture".utf8).base64EncodedString()], "pixelWidth": 10, "pixelHeight": 10])
            try require(recognized.ocrLines.count == 1 && recognized.ocrLines[0]["text"] as? String == "OCR fixture", "structured OCR contract")
            let convertedBox = recognized.ocrLines[0]["boundingBox"] as? [String: Any]
            try require(convertedBox?["x"] as? Double == 0 && convertedBox?["height"] as? Double == 1, "OCR coordinate conversion")
            let dictionary = PluginResponse(raw: ["toDict": ["word": "test", "phonetics": [["type": "us", "value": "test"]], "parts": [["part": "n.", "means": ["测试"]]], "additions": [["name": "例句", "value": "A test."]]]])
            try require(dictionary.format == "markdown" && dictionary.text.contains("测试") && dictionary.text.contains("A test."), "dictionary rendering")
            let tts = try fixture("tts", """
            function tts(query, completion) {
              var signal = $signal.new();
              signal.subscribe(function(value) { completion({result:{type:'base64',value:$data.fromUTF8(value).toBase64()}}); });
              $timer.schedule({interval:0.02,repeats:false,handler:function(){signal.send('RIFFfixture');}});
            }
            """)
            let audio = try await runtime.run(plugin: tts, options: [:], operation: "tts", query: ["text": "hello", "lang": "en"])
            try require(audio.audioData == Data("RIFFfixture".utf8), "TTS binary contract")
            let loop = try fixture("translate", "function translate(query) { while(true) {} }", suffix: "loop")
            let task = Task { try await runtime.run(plugin: loop, options: [:], operation: "translate", query: ["text": "hello"]) }
            try await Task.sleep(nanoseconds: 200_000_000)
            let cancelStart = Date()
            task.cancel()
            do { _ = try await task.value; throw PluginFailure(message: "infinite script ignored cancellation") }
            catch is CancellationError { }
            try require(Date().timeIntervalSince(cancelStart) < 3, "hung JavaScript cancellation")
            try store.setEnabled(false, id: translate.id)
            let installedAfterDisable = try store.list()
            try require(installedAfterDisable.first(where: { $0.id == translate.id })?.enabled == false, "disable persisted")
            let bad = temporary.appendingPathComponent("bad")
            try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: bad.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
            do { _ = try store.install(from: bad); throw PluginFailure(message: "symlink accepted") }
            catch let error as PluginFailure { try require(!error.message.contains("symlink accepted"), "symlink rejected") }
            if let path = ProcessInfo.processInfo.environment["DAX_REAL_PLUGIN"] {
                let plugin = try store.install(from: URL(fileURLWithPath: path))
                let response = try await runtime.run(plugin: plugin, options: [:], operation: "languages", query: [:])
                try require(!(response.raw["languages"] as? [String] ?? []).isEmpty, "real public plugin loaded")
                let query: [String: Any] = ["text": "Hello", "originalText": "Hello", "from": "auto", "to": "auto", "detectFrom": "en", "detectTo": "zh-Hans"]
                var options = ["apiKeys": "test-key-never-sent-outside-loopback", "apiUrl": endpoint + "/v1/chat/completions", "model": "custom", "customModel": "fixture-model", "stream": "disable"]
                let result = try await runtime.run(plugin: plugin, options: options, operation: "translate", query: query)
                try require(result.text == "Public fixture translation", "real plugin non-streaming contract")
                options["stream"] = "enable"
                let streamingResult = try await runtime.run(plugin: plugin, options: options, operation: "translate", query: query)
                try require(streamingResult.text == "Public fixture translation", "real plugin streaming contract")
                print("PASS real plugin with loopback provider: \(plugin.id) \(plugin.descriptor.version), language list + non-streaming + streaming")
            }
            if let path = ProcessInfo.processInfo.environment["DAX_REAL_OCR_PLUGIN"] {
                let plugin = try store.install(from: URL(fileURLWithPath: path))
                let result = try await runtime.run(plugin: plugin, options: ["apiKeys": "synthetic-only", "apiUrl": endpoint, "apiUrlPath": "/v1/chat/completions", "visionModel": "gpt-4o-mini"], operation: "ocr", query: ["image": ["__daxData": Data("image-fixture".utf8).base64EncodedString()], "from": "auto", "detectFrom": "en", "pixelWidth": 10, "pixelHeight": 10])
                try require(result.ocrLines.first?["text"] as? String == "Public fixture translation", "real OCR plugin HTTP and data contract")
                print("PASS real OCR plugin with loopback provider: \(plugin.id) \(plugin.descriptor.version)")
            }
            if let path = ProcessInfo.processInfo.environment["DAX_REAL_TTS_PLUGIN"] {
                let plugin = try store.install(from: URL(fileURLWithPath: path))
                let result = try await runtime.run(plugin: plugin, options: ["api_path": endpoint + "/tts"], operation: "tts", query: ["text": "Hello", "lang": "en"])
                try require(result.audioData == Data("RIFFfixture".utf8), "real TTS plugin binary HTTP contract")
                print("PASS real TTS plugin with loopback provider: \(plugin.id) \(plugin.descriptor.version)")
            }
            print("PASS plugin contracts: modules, crypto, data, sandbox, HTTP, stream, translation, OCR, TTS, timers, signals, cancellation and installation")
        } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
    }
}
