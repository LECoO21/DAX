import Foundation
import JavaScriptCore
import Security

/// The child process owns JavaScriptCore so a blocking or crashing plugin cannot block the UI.
enum PluginWorker {
    private static var host: PluginHost?

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--plugin-worker") else { return }
        do {
            guard let line = readLine(), let data = line.data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PluginFailure(message: "插件任务输入无效。")
            }
            let host = try PluginHost(payload: payload)
            self.host = host
            DispatchQueue.main.async { host.start() }
            DispatchQueue.global(qos: .utility).async {
                while let line = readLine() {
                    if line.contains("\"cancel\"") {
                        DispatchQueue.main.async { host.cancel() }
                        break
                    }
                }
            }
            dispatchMain()
        } catch {
            let message: [String: Any] = ["kind": "error", "message": "无法启动插件运行环境。"]
            if let data = try? JSONSerialization.data(withJSONObject: message) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
            exit(1)
        }
    }
}

private final class PluginHost {
    private let context: JSContext
    private let directory: URL
    private let sandbox: URL
    private let payload: [String: Any]
    private let options: [String: String]
    private let info: [String: Any]
    private var requests: [Int: PluginHTTPRequest] = [:]
    private var sockets: [Int: PluginWebSocket] = [:]
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var nextIdentifier = 0
    private var finished = false
    private var fileMutationCount = 0
    private var fileBytesWritten = 0

    init(payload: [String: Any]) throws {
        guard let path = payload["directory"] as? String, let context = JSContext() else {
            throw PluginFailure(message: "插件运行环境无效。")
        }
        self.context = context
        self.payload = payload
        self.directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        self.options = payload["options"] as? [String: String] ?? [:]
        let data = try Data(contentsOf: directory.appendingPathComponent("info.json"))
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = info["identifier"] as? String,
              identifier.range(of: "^[a-z0-9]+([.][a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw PluginFailure(message: "插件标识无效。")
        }
        self.info = info
        sandbox = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PluginData/\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    func start() {
        context.exceptionHandler = { [weak self] _, exception in
            self?.emit(["kind": "error", "message": "插件脚本异常。\(exception?.toString() ?? "")"])
        }
        context.setObject(options, forKeyedSubscript: "$option" as NSString)
        context.setObject(info, forKeyedSubscript: "$info" as NSString)
        context.setObject(["appVersion": "1.21.2", "appBuild": "263", "appName": "DAX", "macOSVersion": ProcessInfo.processInfo.operatingSystemVersionString, "macModel": "Mac"], forKeyedSubscript: "$env" as NSString)
        let readModule: @convention(block) (String, String) -> [String: String] = { [unowned self] name, parent in
            do { return try self.module(named: name, parent: parent) }
            catch { return ["error": "模块不可访问"] }
        }
        let emit: @convention(block) (JSValue) -> Void = { [unowned self] value in
            if let dictionary = value.toDictionary() as? [String: Any] { self.emit(dictionary) }
        }
        let data: @convention(block) (String, JSValue, JSValue) -> Any = { [unowned self] operation, first, second in
            self.dataOperation(operation, first: first, second: second)
        }
        let file: @convention(block) (String, JSValue) -> Any = { [unowned self] operation, value in
            self.fileOperation(operation, value: value)
        }
        let http: @convention(block) (JSValue, JSValue, Bool) -> Int = { [unowned self] options, handler, streaming in
            self.startHTTP(options: options, handler: handler, streaming: streaming)
        }
        let cancelHTTP: @convention(block) (Int) -> Void = { [unowned self] identifier in self.requests[identifier]?.cancel() }
        let timer: @convention(block) (Double, Bool, JSValue) -> Int = { [unowned self] interval, repeats, handler in
            self.startTimer(interval: interval, repeats: repeats, handler: handler)
        }
        let cancelTimer: @convention(block) (Int) -> Void = { [unowned self] identifier in self.timers.removeValue(forKey: identifier)?.cancel() }
        let websocket: @convention(block) (JSValue, JSValue) -> Int = { [unowned self] options, handler in self.makeWebSocket(options: options, handler: handler) }
        let websocketCommand: @convention(block) (Int, String, JSValue) -> Void = { [unowned self] identifier, action, value in
            self.sockets[identifier]?.command(action, value: value.toObject())
        }
        let random: @convention(block) (Int) -> [Int] = { length in
            guard (0...65536).contains(length) else { return [] }
            var data = [UInt8](repeating: 0, count: length)
            guard SecRandomCopyBytes(kSecRandomDefault, data.count, &data) == errSecSuccess else { return [] }
            return data.map(Int.init)
        }
        context.setObject(readModule, forKeyedSubscript: "_moduleRead" as NSString)
        context.setObject(emit, forKeyedSubscript: "_emit" as NSString)
        context.setObject(data, forKeyedSubscript: "_data" as NSString)
        context.setObject(file, forKeyedSubscript: "_file" as NSString)
        context.setObject(http, forKeyedSubscript: "_http" as NSString)
        context.setObject(cancelHTTP, forKeyedSubscript: "_cancelHTTP" as NSString)
        context.setObject(timer, forKeyedSubscript: "_timer" as NSString)
        context.setObject(cancelTimer, forKeyedSubscript: "_cancelTimer" as NSString)
        context.setObject(websocket, forKeyedSubscript: "_websocket" as NSString)
        context.setObject(websocketCommand, forKeyedSubscript: "_websocketCommand" as NSString)
        context.setObject(random, forKeyedSubscript: "_random" as NSString)
        do {
            let source = try String(contentsOf: resourceURL("BobBridge", extension: "js"), encoding: .utf8)
            context.evaluateScript(source)
            guard !finished else { return }
            let operation = payload["operation"] as? String ?? "translate"
            let query = payload["query"] as? [String: Any] ?? [:]
            context.objectForKeyedSubscript("__invokePlugin")?.call(withArguments: [operation, query])
        } catch { self.emit(["kind": "error", "message": "插件兼容资源加载失败。"] ) }
    }

    func cancel() {
        context.objectForKeyedSubscript("__cancelSignal")?.invokeMethod("send", withArguments: [])
        for request in requests.values { request.cancel() }
        emit(["kind": "error", "message": "插件任务已取消。"])
    }

    private func emit(_ message: [String: Any]) {
        guard !finished else { return }
        var safeMessage = message
        if message["kind"] as? String == "error" {
            var text = message["message"] as? String ?? "插件执行失败。"
            for secret in options.values where secret.count >= 4 { text = text.replacingOccurrences(of: secret, with: "••••") }
            safeMessage["message"] = String(text.prefix(1200))
        }
        guard JSONSerialization.isValidJSONObject(safeMessage), let data = try? JSONSerialization.data(withJSONObject: safeMessage), data.count <= 16 * 1024 * 1024 else {
            emit(["kind": "error", "message": "插件返回数据无法序列化或内容过大。"])
            return
        }
        FileHandle.standardOutput.write(data + Data([10]))
        if ["complete", "error"].contains(message["kind"] as? String ?? "") {
            finished = true
            exit(0)
        }
    }

    private func resourceURL(_ name: String, extension suffix: String) throws -> URL {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "Resources") { return url }
        if let url = Bundle.module.url(forResource: name, withExtension: suffix) { return url }
        #endif
        if let url = Bundle.main.url(forResource: name, withExtension: suffix, subdirectory: "Resources") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: suffix) { return url }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/\(name).\(suffix)")
        if FileManager.default.fileExists(atPath: source.path) { return source }
        throw PluginFailure(message: "运行时资源缺失。")
    }

    private func module(named name: String, parent: String) throws -> [String: String] {
        if name == "crypto-js" {
            return ["path": "/__builtin__/crypto-js.js", "source": try String(contentsOf: resourceURL("crypto-js", extension: "js"), encoding: .utf8)]
        }
        let virtual = name.hasPrefix("/") ? name : (parent as NSString).deletingLastPathComponent + "/" + name
        var path = virtual
        if URL(fileURLWithPath: path).pathExtension.isEmpty { path += ".js" }
        let url = try fileURL(path, writable: false)
        guard url.path.hasPrefix(directory.path + "/") else { throw PluginFailure(message: "模块不在插件目录中。") }
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024, let source = String(data: data, encoding: .utf8) else { throw PluginFailure(message: "模块内容无效。") }
        return ["path": "/" + String(url.path.dropFirst(directory.path.count + 1)), "source": source]
    }

    private func fileURL(_ path: String, writable: Bool) throws -> URL {
        let sandboxPath = path == "$sandbox" || path.hasPrefix("$sandbox/")
        guard sandboxPath || path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { throw PluginFailure(message: "文件路径无效。") }
        if writable && !sandboxPath { throw PluginFailure(message: "插件自身文件为只读。") }
        let base = sandboxPath ? sandbox : directory
        let relative = sandboxPath ? String(path.dropFirst("$sandbox".count)) : path
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        var resolved: [String] = []
        for component in components {
            if component == "." { continue }
            if component == ".." {
                guard !resolved.isEmpty else { throw PluginFailure(message: "文件路径越出插件目录。") }
                resolved.removeLast()
            } else { resolved.append(String(component)) }
        }
        let candidate = resolved.reduce(base) { $0.appendingPathComponent($1) }.resolvingSymlinksInPath().standardizedFileURL
        let realBase = base.resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path == realBase.path || candidate.path.hasPrefix(realBase.path + "/") else { throw PluginFailure(message: "文件路径越出插件目录。") }
        return candidate
    }

    private func fileOperation(_ operation: String, value: JSValue) -> Any {
        do {
            let options = value.isObject ? (value.toDictionary() as? [String: Any] ?? [:]) : [:]
            let path = value.isString ? value.toString()! : (options["path"] as? String ?? "")
            let manager = FileManager.default
            if ["write", "delete", "copy", "move", "mkdir"].contains(operation) {
                fileMutationCount += 1
                guard fileMutationCount <= 5000 else { return false }
            }
            switch operation {
            case "read":
                let data = try Data(contentsOf: fileURL(path, writable: false))
                return data.count <= 32 * 1024 * 1024 ? data.base64EncodedString() as Any : NSNull()
            case "write":
                let destination = try fileURL(path, writable: true)
                guard let data = PluginBinary.data(options["data"]), data.count <= 32 * 1024 * 1024 else { return false }
                fileBytesWritten += data.count
                guard fileBytesWritten <= 64 * 1024 * 1024 else { return false }
                try data.write(to: destination, options: .atomic)
                return true
            case "delete":
                let destination = try fileURL(path, writable: true)
                guard destination != sandbox else { return false }
                try manager.removeItem(at: destination)
                return true
            case "list": return try manager.contentsOfDirectory(atPath: fileURL(path, writable: false).path)
            case "copy", "move":
                let source = try fileURL(options["src"] as? String ?? "", writable: operation == "move")
                let destination = try fileURL(options["dst"] as? String ?? "", writable: true)
                if operation == "copy" {
                    guard (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { return false }
                    fileBytesWritten += try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard fileBytesWritten <= 64 * 1024 * 1024 else { return false }
                    try manager.copyItem(at: source, to: destination)
                } else { try manager.moveItem(at: source, to: destination) }
                return true
            case "mkdir": try manager.createDirectory(at: fileURL(path, writable: true), withIntermediateDirectories: true); return true
            case "exists": return manager.fileExists(atPath: try fileURL(path, writable: false).path)
            case "isDirectory": return try fileURL(path, writable: false).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            default: return NSNull()
            }
        } catch { return ["read", "list"].contains(operation) ? NSNull() : false }
    }

    private func dataOperation(_ operation: String, first: JSValue, second: JSValue) -> Any {
        let string = first.toString() ?? ""
        let data = Data(base64Encoded: string) ?? Data()
        let options = second.isObject && !second.isArray ? (second.toDictionary() as? [String: Any] ?? [:]) : [:]
        switch operation {
        case "fromUTF8": return Data(string.utf8).base64EncodedString()
        case "fromBase64": return Data(base64Encoded: string)?.base64EncodedString() ?? ""
        case "fromHex":
            guard string.count % 2 == 0 else { return "" }
            var bytes = Data()
            var index = string.startIndex
            while index < string.endIndex {
                let next = string.index(index, offsetBy: 2)
                guard let value = UInt8(string[index..<next], radix: 16) else { return "" }
                bytes.append(value)
                index = next
            }
            return bytes.base64EncodedString()
        case "fromBytes": return Data((second.toArray() as? [NSNumber] ?? []).map { UInt8(truncating: $0) }).base64EncodedString()
        case "length": return data.count
        case "utf8": return String(data: data, encoding: .utf8) as Any? ?? NSNull()
        case "hex": return data.map { String(format: "%02x", $0) }.joined()
        case "bytes": return data.map(Int.init)
        case "read": let index = Int(second.toInt32()); return data.indices.contains(index) ? Int(data[index]) : 0
        case "write":
            var mutable = data
            let index = options["index"] as? Int ?? -1
            if mutable.indices.contains(index) { mutable[index] = UInt8(truncatingIfNeeded: options["value"] as? Int ?? 0) }
            return mutable.base64EncodedString()
        case "sub":
            let start = max(0, options["start"] as? Int ?? 0), end = min(data.count, options["end"] as? Int ?? data.count)
            return start < end ? data.subdata(in: start..<end).base64EncodedString() : ""
        case "append": return (data + (Data(base64Encoded: second.toString() ?? "") ?? Data())).base64EncodedString()
        default: return NSNull()
        }
    }

    private func identifier() -> Int { nextIdentifier += 1; return nextIdentifier }

    private func startTimer(interval: Double, repeats: Bool, handler: JSValue) -> Int {
        let id = identifier()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let duration = max(0.01, min(interval.isFinite ? interval : 1, 86400))
        timer.schedule(deadline: .now() + duration, repeating: repeats ? duration : .infinity)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !repeats { self.timers.removeValue(forKey: id)?.cancel() }
            handler.call(withArguments: [])
        }
        timers[id] = timer
        timer.resume()
        return id
    }

    private func startHTTP(options: JSValue, handler: JSValue, streaming: Bool) -> Int {
        let id = identifier()
        let dictionary = options.toDictionary() as? [String: Any] ?? [:]
        do {
            let request = try PluginHTTPRequest(options: dictionary, streaming: streaming) { [weak self] event, complete in
                DispatchQueue.main.async {
                    guard let self, !self.finished else { return }
                    handler.call(withArguments: [event])
                    if complete { self.requests.removeValue(forKey: id) }
                }
            }
            requests[id] = request
            request.start()
        } catch {
            DispatchQueue.main.async { handler.call(withArguments: [["error": ["message": "网络请求参数无效。", "debugMessage": "请求未发送。"]]]) }
        }
        return id
    }

    private func makeWebSocket(options: JSValue, handler: JSValue) -> Int {
        let id = identifier()
        do {
            sockets[id] = try PluginWebSocket(options: options.toDictionary() as? [String: Any] ?? [:]) { event in
                DispatchQueue.main.async { handler.call(withArguments: [event]) }
            }
        } catch {
            DispatchQueue.main.async { handler.call(withArguments: [["kind": "error", "state": 3, "value": ["message": "WebSocket 地址无效。"]]]) }
        }
        return id
    }
}

private enum PluginBinary {
    static func data(_ value: Any?) -> Data? {
        guard let object = value as? [String: Any], let base64 = object["__daxData"] as? String else { return nil }
        return Data(base64Encoded: base64)
    }
    static func object(_ data: Data) -> [String: String] { ["__daxData": data.base64EncodedString()] }
}

private final class PluginHTTPRequest: NSObject, URLSessionDataDelegate {
    private let request: URLRequest
    private let streaming: Bool
    private let handler: ([String: Any], Bool) -> Void
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var utf8Buffer = Data()
    private var totalBytes = 0

    init(options: [String: Any], streaming: Bool, handler: @escaping ([String: Any], Bool) -> Void) throws {
        guard let urlString = options["url"] as? String, var components = URLComponents(string: urlString),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else { throw URLError(.badURL) }
        self.streaming = streaming
        self.handler = handler
        let method = (options["method"] as? String ?? "GET").uppercased()
        let fields = options["body"] as? [String: Any]
        let rawData = PluginBinary.data(options["body"])
        var headers = options["header"] as? [String: String] ?? [:]
        var bodyData: Data?
        func encode(_ fields: [String: Any]) -> String {
            var parts = URLComponents()
            parts.queryItems = fields.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
            return parts.percentEncodedQuery ?? ""
        }
        if rawData == nil, let fields, ["GET", "HEAD", "DELETE"].contains(method) {
            components.queryItems = (components.queryItems ?? []) + fields.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
        } else if let rawData { bodyData = rawData }
        else if !streaming, let files = options["files"] as? [[String: Any]], !files.isEmpty {
            let boundary = "DAX-\(UUID().uuidString)"
            headers = headers.filter { $0.key.lowercased() != "content-type" }
            headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
            var bytes = Data()
            for (name, value) in fields ?? [:] {
                guard !name.contains("\r"), !name.contains("\n"), !name.contains("\"") else { throw URLError(.badURL) }
                bytes.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            for file in files {
                guard let data = PluginBinary.data(file["data"]), let name = file["name"] as? String,
                      let filename = file["filename"] as? String, ![name, filename].contains(where: { $0.contains("\r") || $0.contains("\n") || $0.contains("\"") }) else { throw URLError(.badURL) }
                let mime = file["content-type"] as? String ?? "application/octet-stream"
                guard !mime.contains("\r"), !mime.contains("\n") else { throw URLError(.badURL) }
                bytes.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
                bytes.append(data)
                bytes.append(Data("\r\n".utf8))
            }
            bytes.append(Data("--\(boundary)--\r\n".utf8))
            bodyData = bytes
        } else if let fields {
            let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? "application/x-www-form-urlencoded"
            if contentType.contains("application/json") { bodyData = try JSONSerialization.data(withJSONObject: fields) }
            else { bodyData = Data(encode(fields).utf8); headers["Content-Type"] = "application/x-www-form-urlencoded" }
        }
        guard let url = components.url, (bodyData?.count ?? 0) <= 50 * 1024 * 1024 else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.allHTTPHeaderFields = headers
        request.httpBody = bodyData
        request.timeoutInterval = min(max(options["timeout"] as? Double ?? 60, 1), 300)
        self.request = request
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func start() { task = session.dataTask(with: request); task?.resume() }
    func cancel() { task?.cancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "") else { completionHandler(nil); return }
        var safe = request
        if request.url?.host != self.request.url?.host || request.url?.scheme != self.request.url?.scheme {
            let publicHeaders = Set(["accept", "accept-language", "content-type", "user-agent"])
            safe.allHTTPHeaderFields = (safe.allHTTPHeaderFields ?? [:]).filter { publicHeaders.contains($0.key.lowercased()) }
        }
        completionHandler(safe)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        totalBytes += data.count
        guard totalBytes <= 32 * 1024 * 1024 else { dataTask.cancel(); return }
        if streaming {
            utf8Buffer.append(data)
            let text = String(data: utf8Buffer, encoding: .utf8) ?? ""
            if !text.isEmpty { utf8Buffer.removeAll(keepingCapacity: true) }
            handler(["stream": ["text": text, "rawData": PluginBinary.object(data)]], false)
        } else { body.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var result: [String: Any] = [:]
        if let response {
            result["response"] = ["url": response.url?.absoluteString ?? "", "MIMEType": response.mimeType ?? "", "expectedContentLength": response.expectedContentLength, "textEncodingName": response.textEncodingName ?? "", "suggestedFilename": response.suggestedFilename ?? "", "statusCode": response.statusCode, "headers": response.allHeaderFields]
        }
        if error != nil {
            result["error"] = ["message": "网络请求失败或已取消。", "debugMessage": "请检查网络和服务配置。"]
        } else if !streaming {
            result["rawData"] = PluginBinary.object(body)
            result["data"] = (try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)) ?? String(data: body, encoding: .utf8) as Any? ?? PluginBinary.object(body)
        }
        handler(result, true)
        session.finishTasksAndInvalidate()
    }
}

private final class PluginWebSocket: NSObject, URLSessionWebSocketDelegate {
    private let request: URLRequest
    private let handler: ([String: Any]) -> Void
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(options: [String: Any], handler: @escaping ([String: Any]) -> Void) throws {
        guard let value = options["url"] as? String, let url = URL(string: value), ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = options["header"] as? [String: String]
        request.timeoutInterval = min(max(options["timeoutInterval"] as? Double ?? 60, 1), 300)
        self.request = request
        self.handler = handler
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }
    func command(_ action: String, value: Any?) {
        switch action {
        case "open":
            guard task == nil else { return }
            task = session.webSocketTask(with: request)
            task?.resume()
            receiveTask = Task { [weak self] in await self?.receive() }
        case "close":
            let code = (value as? [String: Any])?["code"] as? Int ?? 1000
            task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
            receiveTask?.cancel()
        case "text":
            if let text = value as? String { Task { [weak self] in try? await self?.task?.send(.string(text)) } }
        case "data":
            if let data = PluginBinary.data(value) { Task { [weak self] in try? await self?.task?.send(.data(data)) } }
        case "ping": task?.sendPing { [weak self] error in
            self?.handler(error == nil ? ["kind": "pong", "value": PluginBinary.object(Data())] : ["kind": "error", "value": ["message": "WebSocket 心跳失败。"]])
        }
        case "pong": break // URLSession responds to incoming ping frames automatically.
        default: break
        }
    }
    private func receive() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                switch try await task.receive() {
                case .string(let text): handler(["kind": "text", "value": text])
                case .data(let data): handler(["kind": "data", "value": PluginBinary.object(data)])
                @unknown default: break
                }
            } catch {
                handler(["kind": "error", "state": 3, "value": ["message": "WebSocket 连接中断。"]])
                return
            }
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { handler(["kind": "open", "state": 1]) }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handler(["kind": "close", "state": 3, "code": closeCode.rawValue, "reason": reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""])
        session.finishTasksAndInvalidate()
    }
}
