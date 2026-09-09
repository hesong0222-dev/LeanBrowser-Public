import Foundation
import Security

struct CredentialOrigin: Hashable, Codable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let scheme = components.scheme, let host = components.host else { return nil }
        self.init(scheme: scheme, host: host, port: components.port)
    }

    init?(scheme rawScheme: String, host rawHost: String, port rawPort: Int? = nil) {
        let scheme = rawScheme.lowercased()
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard (scheme == "https" || scheme == "http"), !host.isEmpty else { return nil }
        if scheme == "http" && !Self.isLoopback(host) { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = rawPort ?? defaultPort
        guard (1...65_535).contains(port) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    var canonical: String {
        let printableHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(printableHost):\(port)"
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

struct SubmittedCredential: Codable {
    let username: String
    let password: String
}

enum CredentialStoreError: Error {
    case keychain(OSStatus)
    case invalidPayload
    case unavailable
}

final class CredentialStore {
    static let defaultService = Bundle.main.bundleIdentifier.map { "\($0).credentials.v1" }

    private let service: String?
    init(service: String? = CredentialStore.defaultService) { self.service = service }

    func upsert(_ credential: SubmittedCredential, for origin: CredentialOrigin) throws {
        let service = try availableService()
        let data = try JSONEncoder().encode(credential)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: origin.canonical,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        var add = query
        add[kSecValueData] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard update == errSecSuccess else { throw CredentialStoreError.keychain(update) }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychain(status)
        }
    }

    func credential(for origin: CredentialOrigin) throws -> SubmittedCredential? {
        let service = try availableService()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: origin.canonical,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStoreError.keychain(status) }
        guard let credential = try? JSONDecoder().decode(SubmittedCredential.self, from: data) else { throw CredentialStoreError.invalidPayload }
        return credential
    }

    func delete(for origin: CredentialOrigin) throws {
        let service = try availableService()
        let status = SecItemDelete(baseQuery(origin: origin, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }

    func deleteAll() throws {
        let service = try availableService()
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrSynchronizable: kCFBooleanFalse as Any]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }

    private func baseQuery(origin: CredentialOrigin, service: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: origin.canonical, kSecAttrSynchronizable: kCFBooleanFalse as Any]
    }

    private func availableService() throws -> String {
        guard let service else { throw CredentialStoreError.unavailable }
        return service
    }
}
