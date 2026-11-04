import Foundation
import Security

struct KeychainAccessFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum KeychainAccess {
    private static let queue = DispatchQueue(label: "com.leco.dax.keychain", qos: .userInitiated)
    private static let helperRequirement = "identifier \"com.leco.dax.credentials-helper\" and certificate root = H\"909a66d494eacc5c5b7d41181813e7a7c4854d9a\""

    struct Response: Decodable {
        var status: OSStatus
        var data: Data?
        var exists: Bool?
    }
    private struct Request: Encodable {
        let operation: String
        let service: String
        let account: String
        let data: Data?
        let interactive: Bool
    }

    static func run<Value>(_ operation: @escaping () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let value: Value = try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
        try Task.checkCancellation()
        return value
    }

    static func request(_ operation: String, service: String, account: String,
                        data: Data? = nil, interactive: Bool = false) async throws -> Response {
        let request = Request(operation: operation, service: service, account: account, data: data, interactive: interactive)
        return try await run { try execute(request) }
    }

    private static func execute(_ request: Request) throws -> Response {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DAXCredentials")
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(helperRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw KeychainAccessFailure(message: "DAX 凭据组件缺失或签名无效，请重新安装完整应用。")
        }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + (request.interactive ? 120 : 15), execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
        try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard bytes.count <= 1_500_000, let response = try? JSONDecoder().decode(Response.self, from: bytes) else {
            throw KeychainAccessFailure(message: "凭据访问未完成，请确认系统授权窗口或稍后重试。")
        }
        if response.status == errSecInteractionNotAllowed || response.status == errSecAuthFailed {
            throw KeychainAccessFailure(message: "密钥需要一次性授权，请在服务设置中点击“授权读取密钥”。")
        }
        guard response.status == errSecSuccess else {
            throw KeychainAccessFailure(message: "无法访问钥匙串，请检查锁定或授权状态（\(response.status)）。")
        }
        return response
    }
}
