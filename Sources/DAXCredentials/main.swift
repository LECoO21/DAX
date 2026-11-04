import Foundation
import Security
import Darwin

private struct Request: Decodable {
    let operation: String
    let service: String
    let account: String
    let data: Data?
    let interactive: Bool
}

private struct Response: Encodable {
    var status: OSStatus
    var data: Data? = nil
    var exists: Bool? = nil
}

private func trustedParent() -> Bool {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: getppid()]
    guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
          let code else { return false }
    var requirement: SecRequirement?
    let identity = "identifier \"com.leco.dax\" and certificate root = H\"909a66d494eacc5c5b7d41181813e7a7c4854d9a\""
    guard SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

private func execute(_ request: Request) -> Response {
    let validAccount: Bool
    switch request.service {
    case "com.leco.dax.credentials": validAccount = UUID(uuidString: request.account) != nil
    case "com.dax.plugin.options":
        validAccount = request.account.range(of: "^[a-z0-9]+([.][a-z0-9]+)*$", options: .regularExpression) != nil
    default: return Response(status: errSecParam)
    }
    guard validAccount, ["load", "exists", "save", "delete", "authorize"].contains(request.operation) else {
        return Response(status: errSecParam)
    }
    // Only explicit settings actions may present system authorization. Ordinary
    // translations fail with a recoverable card message when permission is missing.
    let allowInteraction = request.interactive && ["save", "delete", "authorize"].contains(request.operation)
    SecKeychainSetUserInteractionAllowed(allowInteraction)
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: request.service,
        kSecAttrAccount as String: request.account
    ]
    switch request.operation {
    case "load", "authorize", "exists":
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[request.operation == "exists" ? kSecReturnAttributes as String : kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return Response(status: errSecSuccess, exists: false) }
        guard status == errSecSuccess else { return Response(status: status) }
        if request.operation == "load" {
            guard let data = value as? Data else { return Response(status: errSecDecode) }
            return Response(status: status, data: data, exists: true)
        }
        return Response(status: status, exists: true)
    case "save":
        guard let data = request.data, !data.isEmpty, data.count <= 1_048_576 else { return Response(status: errSecParam) }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { return Response(status: status) }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return Response(status: SecItemAdd(query as CFDictionary, nil))
    case "delete":
        let status = SecItemDelete(query as CFDictionary)
        return Response(status: status == errSecItemNotFound ? errSecSuccess : status)
    default: return Response(status: errSecParam)
    }
}

private func respond(_ response: Response) {
    if let data = try? JSONEncoder().encode(response) {
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

guard trustedParent() else { respond(Response(status: errSecAuthFailed)); exit(1) }
let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= 1_500_000, let request = try? JSONDecoder().decode(Request.self, from: input) else {
    respond(Response(status: errSecParam)); exit(1)
}
respond(execute(request))
