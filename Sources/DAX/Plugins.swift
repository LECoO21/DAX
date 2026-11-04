import Foundation
import Security
import CryptoKit

struct PluginDescriptor: Codable, Identifiable {
    var id: String { identifier }
    let identifier: String
    let version: String
    let category: String
    let name: String
    let summary: String?
    let author: String?
    let homepage: String?
    let appcast: String?
    let minBobVersion: String?
    let options: [PluginOption]?
}

struct PluginOption: Codable, Identifiable {
    var id: String { identifier }
    let identifier: String
    let type: String
    let title: String
    let defaultValue: String?
    let desc: String?
    let textConfig: TextConfig?
    let menuValues: [MenuValue]?
    var isSecure: Bool { type == "text" && textConfig?.type != "visible" }
    struct TextConfig: Codable {
        let type: String?
        let placeholderText: String?
        let height: Double?
        private enum CodingKeys: String, CodingKey { case type, placeholderText, height }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decodeIfPresent(String.self, forKey: .type)
            placeholderText = try values.decodeIfPresent(String.self, forKey: .placeholderText)
            if let number = try? values.decode(Double.self, forKey: .height) { height = number }
            else { height = (try? values.decode(String.self, forKey: .height)).flatMap(Double.init) }
        }
    }
    struct MenuValue: Codable { let title: String; let value: String }
}

struct InstalledPlugin: Identifiable {
    var id: String { descriptor.identifier }
    let descriptor: PluginDescriptor
    let directoryURL: URL
    let enabled: Bool
}

struct PluginResponse {
    let raw: [String: Any]
    var text: String {
        if let content = raw["content"] as? [String: Any] {
            if let text = content["text"] as? String { return text }
            if let lines = content["lines"] as? [String] { return lines.joined(separator: "\n") }
        }
        if let paragraphs = raw["toParagraphs"] as? [String] { return paragraphs.joined(separator: "\n") }
        if !ocrLines.isEmpty { return ocrLines.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        if let dictionary { return Self.dictionaryMarkdown(dictionary) }
        return raw["text"] as? String ?? ""
    }
    var dictionary: [String: Any]? { raw["toDict"] as? [String: Any] }
    var thinkingText: String? { (raw["thinkInfo"] as? [String: Any])?["content"] as? String }
    var format: String {
        if let content = raw["content"] as? [String: Any] { return content["format"] as? String ?? "plain" }
        if raw["toParagraphs"] == nil, dictionary != nil { return "markdown" }
        return "plain"
    }
    private static func dictionaryMarkdown(_ dictionary: [String: Any]) -> String {
        var sections: [String] = []
        if let word = dictionary["word"] as? String { sections.append("## " + word) }
        let phonetics = (dictionary["phonetics"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            guard let value = item["value"] as? String else { return nil }
            let label = item["type"] as? String == "uk" ? "英" : "美"
            return label + " /" + value + "/"
        }
        if !phonetics.isEmpty { sections.append(phonetics.joined(separator: "  ")) }
        for item in dictionary["parts"] as? [[String: Any]] ?? [] {
            let part = item["part"] as? String ?? ""
            let means = (item["means"] as? [String] ?? []).joined(separator: "；")
            if !means.isEmpty { sections.append(part.isEmpty ? means : "**" + part + "** " + means) }
        }
        for item in dictionary["exchanges"] as? [[String: Any]] ?? [] {
            let name = item["name"] as? String ?? ""
            let words = (item["words"] as? [String] ?? []).joined(separator: "、")
            if !words.isEmpty { sections.append(name + " " + words) }
        }
        for group in dictionary["relatedWordParts"] as? [[String: Any]] ?? [] {
            let part = group["part"] as? String ?? ""
            let words = (group["words"] as? [[String: Any]] ?? []).compactMap { item -> String? in
                guard let word = item["word"] as? String else { return nil }
                let means = (item["means"] as? [String] ?? []).joined(separator: "；")
                return "- **" + word + "** " + means
            }
            if !words.isEmpty { sections.append(([part] + words).filter { !$0.isEmpty }.joined(separator: "\n")) }
        }
        for item in dictionary["additions"] as? [[String: Any]] ?? [] {
            guard let value = item["value"] as? String else { continue }
            let name = item["name"] as? String ?? ""
            sections.append(name.isEmpty ? value : "### " + name + "\n" + value)
        }
        return sections.joined(separator: "\n\n")
    }
    var audioData: Data? { raw["type"] as? String == "base64" ? (raw["value"] as? String).flatMap { Data(base64Encoded: $0) } : nil }
    var audioURL: URL? {
        guard raw["type"] as? String == "url", let value = raw["value"] as? String,
              let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    var ocrLines: [[String: Any]] {
        let lines: [[String: Any]]
        if let flat = raw["texts"] as? [[String: Any]] {
            lines = flat
        } else {
            lines = (raw["regionInfos"] as? [[String: Any]] ?? []).flatMap { region -> [[String: Any]] in
                let paragraphs = region["paragraphInfos"] as? [[String: Any]] ?? []
                let rows = paragraphs.flatMap { paragraph -> [[String: Any]] in
                    let texts = paragraph["texts"] as? [[String: Any]] ?? []
                    if let box = paragraph["boundingBox"], texts.allSatisfy({ $0["boundingBox"] == nil }) {
                        return [["text": texts.compactMap { $0["text"] as? String }.joined(separator: "\n"), "boundingBox": box]]
                    }
                    return texts
                }
                if let box = region["boundingBox"], rows.allSatisfy({ $0["boundingBox"] == nil }) {
                    return [["text": rows.compactMap { $0["text"] as? String }.joined(separator: "\n"), "boundingBox": box]]
                }
                return rows
            }
        }
        return lines.map { original in
            var line = original
            guard var box = original["boundingBox"] as? [String: Any],
                  let points = box["points"] as? [[String: Double]], points.count >= 4 else { return line }
            let xs = points.compactMap { $0["x"] }, ys = points.compactMap { $0["y"] }
            guard xs.count == points.count, ys.count == points.count,
                  xs.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  ys.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
                  maxX > minX, maxY > minY else { return line }
            // Bob points are top-left normalized. The app's OCR geometry uses bottom-left normalized rectangles.
            box["x"] = minX
            box["y"] = 1 - maxY
            box["width"] = maxX - minX
            box["height"] = maxY - minY
            line["boundingBox"] = box
            return line
        }
    }
}

struct PluginUpdate {
    let identifier: String
    let version: String
    let downloadURL: URL
    let sha256: String
    let description: String
}

struct PluginFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class PluginStore {
    let rootURL: URL
    let sandboxURL: URL
    private let fileManager = FileManager.default

    init(rootURL: URL? = nil) throws {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.rootURL = rootURL ?? support.appendingPathComponent("DAX/Plugins", isDirectory: true)
        self.sandboxURL = self.rootURL.deletingLastPathComponent().appendingPathComponent("PluginData", isDirectory: true)
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: self.sandboxURL, withIntermediateDirectories: true)
    }

    func list() throws -> [InstalledPlugin] {
        try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            .compactMap { url in
                guard let descriptor = try? readDescriptor(at: url) else { return nil }
                let enabled = !fileManager.fileExists(atPath: url.appendingPathComponent(".disabled").path)
                return InstalledPlugin(descriptor: descriptor, directoryURL: url, enabled: enabled)
            }.sorted { $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending }
    }

    @discardableResult
    func install(from source: URL, expectedIdentifier: String? = nil, expectedVersion: String? = nil) throws -> InstalledPlugin {
        let stage = rootURL.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stage) }
        let isDirectory = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        if isDirectory {
            try validateDirectory(source)
            for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try fileManager.copyItem(at: item, to: stage.appendingPathComponent(item.lastPathComponent))
            }
        } else {
            try validateArchive(source)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", source.path, "-d", stage.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning {
                if Date() >= deadline {
                    process.terminate()
                    process.waitUntilExit()
                    throw PluginFailure(message: "插件解压超时。")
                }
                do { try validateDirectory(stage) }
                catch {
                    process.terminate()
                    process.waitUntilExit()
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard process.terminationStatus == 0 else { throw PluginFailure(message: "插件压缩包无法解压。") }
            try validateDirectory(stage)
        }
        var package = stage
        if !fileManager.fileExists(atPath: stage.appendingPathComponent("info.json").path) {
            let directories = try fileManager.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                .filter { $0.lastPathComponent != "__MACOSX" }
            guard directories.count == 1 else { throw PluginFailure(message: "插件根目录需要包含 info.json 和 main.js。") }
            package = directories[0]
        }
        let descriptor = try readDescriptor(at: package)
        if let expectedIdentifier, descriptor.identifier != expectedIdentifier {
            throw PluginFailure(message: "更新包的插件标识不匹配。")
        }
        if let expectedVersion, descriptor.version != expectedVersion {
            throw PluginFailure(message: "更新包的插件版本不匹配。")
        }
        let destination = rootURL.appendingPathComponent(descriptor.identifier, isDirectory: true)
        let backup = rootURL.appendingPathComponent(".backup-\(UUID().uuidString)")
        let wasInstalled = fileManager.fileExists(atPath: destination.path)
        let wasDisabled = fileManager.fileExists(atPath: destination.appendingPathComponent(".disabled").path)
        if wasInstalled { try fileManager.moveItem(at: destination, to: backup) }
        do {
            try fileManager.moveItem(at: package, to: destination)
            if wasDisabled { try Data().write(to: destination.appendingPathComponent(".disabled")) }
            if wasInstalled { try? fileManager.removeItem(at: backup) }
        } catch {
            if fileManager.fileExists(atPath: destination.path) { try? fileManager.removeItem(at: destination) }
            if wasInstalled { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
        return InstalledPlugin(descriptor: descriptor, directoryURL: destination, enabled: !wasDisabled)
    }

    func checkUpdate(for plugin: InstalledPlugin) async throws -> PluginUpdate? {
        guard let value = plugin.descriptor.appcast, let url = URL(string: value), url.scheme == "https" else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard data.count <= 2 * 1024 * 1024, (response as? HTTPURLResponse)?.statusCode == 200,
              let cast = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              cast["identifier"] as? String == plugin.id,
              let versions = cast["versions"] as? [[String: Any]] else { throw PluginFailure(message: "插件更新信息无效。") }
        for version in versions {
            guard let number = version["version"] as? String,
                  number.compare(plugin.descriptor.version, options: .numeric) == .orderedDescending,
                  let address = version["url"] as? String, let download = URL(string: address), download.scheme == "https",
                  let hash = version["sha256"] as? String,
                  hash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { continue }
            if let minimum = version["minBobVersion"] as? String, minimum.compare("1.21.2", options: .numeric) == .orderedDescending { continue }
            return PluginUpdate(identifier: plugin.id, version: number, downloadURL: download, sha256: hash.lowercased(), description: version["desc"] as? String ?? "")
        }
        return nil
    }

    @discardableResult
    func install(update: PluginUpdate) async throws -> InstalledPlugin {
        let (file, response) = try await URLSession.shared.download(from: update.downloadURL)
        defer { try? fileManager.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 64 * 1024 * 1024 else {
            throw PluginFailure(message: "插件更新下载失败或内容过大。")
        }
        let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard hash == update.sha256 else { throw PluginFailure(message: "插件更新校验失败，原插件已保留。") }
        return try install(from: file, expectedIdentifier: update.identifier, expectedVersion: update.version)
    }

    func setEnabled(_ enabled: Bool, id: String) throws {
        try validateIdentifier(id)
        let directory = rootURL.appendingPathComponent(id)
        _ = try readDescriptor(at: directory)
        let flag = directory.appendingPathComponent(".disabled")
        if enabled {
            if fileManager.fileExists(atPath: flag.path) { try fileManager.removeItem(at: flag) }
        } else { try Data().write(to: flag) }
    }

    func remove(id: String) async throws {
        try validateIdentifier(id)
        try await PluginOptionsStore.delete(pluginID: id)
        let directory = rootURL.appendingPathComponent(id)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
        let sandbox = sandboxURL.appendingPathComponent(id)
        if fileManager.fileExists(atPath: sandbox.path) { try fileManager.removeItem(at: sandbox) }
    }

    func saveOptions(_ options: [String: String], pluginID: String) async throws {
        try validateIdentifier(pluginID)
        try await PluginOptionsStore.save(options, pluginID: pluginID)
    }

    func loadOptions(for plugin: InstalledPlugin) async throws -> [String: String] {
        var options = Dictionary(uniqueKeysWithValues: (plugin.descriptor.options ?? []).map { ($0.identifier, $0.defaultValue ?? "") })
        guard !options.isEmpty else { return [:] }
        options.merge(try await PluginOptionsStore.load(pluginID: plugin.id)) { _, new in new }
        return options
    }

    func readDescriptor(at directory: URL) throws -> PluginDescriptor {
        let data = try Data(contentsOf: directory.appendingPathComponent("info.json"))
        guard data.count < 1_048_576 else { throw PluginFailure(message: "插件信息文件过大。") }
        let descriptor = try JSONDecoder().decode(PluginDescriptor.self, from: data)
        try validateIdentifier(descriptor.identifier)
        guard ["translate", "ocr", "tts"].contains(descriptor.category),
              descriptor.version.range(of: "^[0-9a-z]+([.][0-9a-z]+)*$", options: .regularExpression) != nil,
              !descriptor.name.isEmpty,
              fileManager.fileExists(atPath: directory.appendingPathComponent("main.js").path) else {
            throw PluginFailure(message: "插件描述或入口无效。")
        }
        let identifiers = (descriptor.options ?? []).map(\.identifier)
        guard Set(identifiers).count == identifiers.count, identifiers.allSatisfy({ !$0.isEmpty }),
              (descriptor.options ?? []).allSatisfy({ ["text", "menu"].contains($0.type) && ($0.type != "menu" || $0.menuValues != nil) }) else {
            throw PluginFailure(message: "插件选项包含重复标识或无效类型。")
        }
        if let minimum = descriptor.minBobVersion, minimum.compare("1.21.2", options: .numeric) == .orderedDescending {
            throw PluginFailure(message: "该插件需要更新版本的 Bob 插件接口，目前兼容基准为 1.21.2。")
        }
        return descriptor
    }

    func resourceURL(forBobPluginURL url: URL) throws -> URL {
        guard url.scheme == "bob-plugin", let identifier = url.host else { throw PluginFailure(message: "插件资源地址无效。") }
        try validateIdentifier(identifier)
        let installed = rootURL.appendingPathComponent(identifier)
        _ = try readDescriptor(at: installed)
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains("."), !url.path.contains("\\"), !url.path.contains("\0") else {
            throw PluginFailure(message: "插件资源路径无效。")
        }
        let isSandbox = components.first == "$sandbox"
        let base = (isSandbox ? sandboxURL.appendingPathComponent(identifier) : installed).resolvingSymlinksInPath()
        let relative = isSandbox ? Array(components.dropFirst()) : components
        let result = relative.reduce(base) { $0.appendingPathComponent($1) }.resolvingSymlinksInPath()
        guard result.path.hasPrefix(base.path + "/"), (try result.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw PluginFailure(message: "插件资源不存在或不可访问。")
        }
        return result
    }

    private func validateIdentifier(_ value: String) throws {
        guard value.range(of: "^[a-z0-9]+([.][a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw PluginFailure(message: "插件标识必须由小写字母、数字和点组成。")
        }
    }

    private func validateDirectory(_ root: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else { throw PluginFailure(message: "无法读取插件目录。") }
        var count = 0
        var total = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw PluginFailure(message: "插件不能包含符号链接或特殊文件。")
            }
            count += 1
            total += values.fileSize ?? 0
            guard count <= 5000, total <= 64 * 1024 * 1024 else { throw PluginFailure(message: "插件超过 64 MB 或 5000 个文件的安装限制。") }
        }
    }

    private func validateArchive(_ url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 22, size <= 64 * 1024 * 1024 else { throw PluginFailure(message: "插件包大小无效。") }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 22, bytes.count <= 64 * 1024 * 1024 else { throw PluginFailure(message: "插件包大小无效。") }
        func u16(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
        func u32(_ p: Int) -> UInt32 { UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24 }
        let lower = max(0, bytes.count - 65_557)
        guard let end = stride(from: bytes.count - 22, through: lower, by: -1).first(where: { u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == bytes.count }),
              u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == u16(end + 10) else {
            throw PluginFailure(message: "仅支持普通 ZIP 格式的 .bobplugin 文件。")
        }
        let count = u16(end + 10)
        var cursor = Int(u32(end + 16))
        guard count > 0, count <= 5000, cursor < end else { throw PluginFailure(message: "插件 ZIP 索引无效。") }
        var total: UInt64 = 0
        var names = Set<String>()
        for _ in 0..<count {
            guard cursor >= 0, cursor + 46 <= end, u32(cursor) == 0x02014b50 else { throw PluginFailure(message: "插件 ZIP 目录损坏。") }
            let nameLength = u16(cursor + 28), extraLength = u16(cursor + 30), commentLength = u16(cursor + 32)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, next <= end,
                  let name = String(data: bytes.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains("."),
                  !name.contains("\n"), names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  u16(cursor + 8) & 1 == 0 else { throw PluginFailure(message: "插件 ZIP 包含不安全或重复的路径。") }
            let mode = (u32(cursor + 38) >> 16) & 0xf000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 else { throw PluginFailure(message: "插件 ZIP 包含特殊文件。") }
            let local = Int(u32(cursor + 42))
            guard local >= 0, local + 30 <= cursor, u32(local) == 0x04034b50,
                  u16(local + 26) == nameLength, u16(local + 6) == u16(cursor + 8), u16(local + 8) == u16(cursor + 10),
                  local + 30 + nameLength <= bytes.count,
                  bytes.subdata(in: local + 30..<local + 30 + nameLength) == bytes.subdata(in: cursor + 46..<cursor + 46 + nameLength) else {
                throw PluginFailure(message: "插件 ZIP 文件索引不一致。")
            }
            total += UInt64(u32(cursor + 24))
            guard total <= 64 * 1024 * 1024 else { throw PluginFailure(message: "插件解压后超过 64 MB。") }
            cursor = next
        }
    }
}

/// Every plugin option is protected in the keychain, including values whose secrecy a plugin did not declare.
enum PluginOptionsStore {
    private static let service = "com.dax.plugin.options"

    static func load(pluginID: String) async throws -> [String: String] {
        let response = try await KeychainAccess.request("load", service: service, account: pluginID)
        guard let data = response.data else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
    static func authorize(pluginID: String) async throws {
        _ = try await KeychainAccess.request("authorize", service: service, account: pluginID, interactive: true)
        _ = try await load(pluginID: pluginID)
    }
    static func save(_ options: [String: String], pluginID: String) async throws {
        _ = try await KeychainAccess.request("save", service: service, account: pluginID,
                                            data: JSONEncoder().encode(options), interactive: true)
    }
    static func delete(pluginID: String) async throws {
        _ = try await KeychainAccess.request("delete", service: service, account: pluginID, interactive: true)
    }
}

final class BobPluginRuntime {
    private let executableURL: URL
    init(executableURL: URL = Bundle.main.executableURL!) { self.executableURL = executableURL }

    func run(plugin: InstalledPlugin, options: [String: String], operation: String,
             query: [String: Any], onStream: @escaping (PluginResponse) -> Void = { _ in }) async throws -> PluginResponse {
        guard plugin.enabled else { throw PluginFailure(message: "此插件已停用。") }
        let payload: [String: Any] = ["directory": plugin.directoryURL.path, "options": options, "operation": operation, "query": query]
        let process = PluginProcess(executableURL: executableURL, payload: payload, onStream: onStream)
        return try await withTaskCancellationHandler {
            try await process.run()
        } onCancel: { process.cancel() }
    }
}

private final class PluginProcess: @unchecked Sendable {
    private let executableURL: URL
    private let payload: [String: Any]
    private let onStream: (PluginResponse) -> Void
    private let lock = NSLock()
    private var child: Process?
    private var input: Pipe?
    private var continuation: CheckedContinuation<PluginResponse, Error>?
    private var terminal: Result<PluginResponse, Error>?
    private var timeoutWork: DispatchWorkItem?
    private var acceptedPluginTimeout = false
    private let startedAt = Date()

    init(executableURL: URL, payload: [String: Any], onStream: @escaping (PluginResponse) -> Void) {
        self.executableURL = executableURL; self.payload = payload; self.onStream = onStream
    }

    func run() async throws -> PluginResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let terminal { lock.unlock(); continuation.resume(with: terminal); return }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { self.launch() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func launch() {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard data.count <= 50 * 1024 * 1024 else { throw PluginFailure(message: "插件请求内容过大。") }
            let process = Process()
            let stdin = Pipe(), stdout = Pipe()
            process.executableURL = executableURL
            process.arguments = ["--plugin-worker"]
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            lock.lock()
            guard terminal == nil else { lock.unlock(); return }
            child = process; input = stdin
            do { try process.run() } catch { lock.unlock(); throw error }
            lock.unlock()
            process.terminationHandler = { [weak self] child in
                // Output reader consumes a valid completion before reporting EOF.
                if child.terminationReason == .uncaughtSignal { self?.finish(.failure(PluginFailure(message: "插件进程异常结束。"))) }
            }
            scheduleTimeout(seconds: 65)
            try stdin.fileHandleForWriting.write(contentsOf: data + Data([10]))
            var buffer = Data()
            while true {
                let part = stdout.fileHandleForReading.availableData
                if part.isEmpty { break }
                buffer.append(part)
                guard buffer.count <= 32 * 1024 * 1024 else { throw PluginFailure(message: "插件返回内容过大。") }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let kind = message["kind"] as? String else { continue }
                    if kind == "stream", let raw = message["result"] as? [String: Any] { onStream(PluginResponse(raw: raw)) }
                    if kind == "complete", let raw = message["result"] as? [String: Any] { finish(.success(PluginResponse(raw: raw))); return }
                    if kind == "error" { finish(.failure(PluginFailure(message: message["message"] as? String ?? "插件执行失败。"))); return }
                    if kind == "timeout", let interval = message["seconds"] as? Double {
                        // Worker enforces the documented plugin interval. The parent also bounds stuck JavaScript.
                        lock.lock()
                        let accept = !acceptedPluginTimeout
                        acceptedPluginTimeout = true
                        lock.unlock()
                        if accept { scheduleTimeout(seconds: min(max(interval, 30), 300) + 5) }
                    }
                }
            }
            finish(.failure(PluginFailure(message: "插件没有返回结果。")))
        } catch { finish(.failure(error)) }
    }

    private func scheduleTimeout(seconds: Double) {
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(PluginFailure(message: "插件执行超时，请检查插件配置。")))
        }
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        timeoutWork?.cancel()
        timeoutWork = work
        lock.unlock()
        let remaining = max(0, seconds - Date().timeIntervalSince(startedAt))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func finish(_ value: Result<PluginResponse, Error>) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = value
        timeoutWork?.cancel()
        timeoutWork = nil
        let continuation = self.continuation
        self.continuation = nil
        let process = child
        let input = self.input
        self.input = nil
        lock.unlock()
        if let input { try? input.fileHandleForWriting.write(contentsOf: Data("{\"cancel\":true}\n".utf8)); try? input.fileHandleForWriting.close() }
        if let process, process.isRunning { process.terminate() }
        continuation?.resume(with: value)
    }
}
