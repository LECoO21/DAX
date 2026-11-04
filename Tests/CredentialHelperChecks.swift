import Foundation

@main
struct CredentialHelperChecks {
    static func main() async throws {
        let operation = CommandLine.arguments[1]
        let account = CommandLine.arguments[2]
        let service = "com.leco.dax.credentials"
        let synthetic = Data("DAX disposable credential fixture".utf8)
        switch operation {
        case "write":
            _ = try await KeychainAccess.request("save", service: service, account: account, data: synthetic)
        case "read":
            let response = try await KeychainAccess.request("load", service: service, account: account)
            guard response.data == synthetic else { fatalError("Stored fixture differs") }
        case "deny":
            do {
                _ = try await KeychainAccess.request("load", service: service, account: account)
                fatalError("An untrusted caller was accepted")
            } catch let error as KeychainAccessFailure {
                guard error.message.contains("一次性授权") else { throw error }
            }
        case "delete":
            _ = try await KeychainAccess.request("delete", service: service, account: account)
        default: fatalError("Unknown test operation")
        }
        #if UPDATED_HOST
        print("PASS credential helper \(operation), updated host")
        #else
        print("PASS credential helper \(operation), original host")
        #endif
    }
}
