import Foundation
import Security

public struct Credentials: Sendable, Equatable {
    public var email: String
    public var password: String
    public init(email: String, password: String) { self.email = email; self.password = password }
}

/// Credential storage seam so tests never touch the real Keychain.
public protocol CredentialStore: Sendable {
    func save(email: String, password: String) throws
    func load(email: String) throws -> String?
    /// The stored account, whichever email it was saved under.
    func loadAccount() throws -> Credentials?
    func delete(email: String) throws
}

public struct KeychainError: LocalizedError {
    public var status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Generic-password items: service `com.oliverames.ThingsRemindersSync`, account = email.
public struct Keychain: CredentialStore {
    public static let defaultService = "com.oliverames.ThingsRemindersSync"
    public let service: String

    public init(service: String = Keychain.defaultService) { self.service = service }

    private func base(_ email: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let email { q[kSecAttrAccount as String] = email }
        return q
    }

    public func save(email: String, password: String) throws {
        let data = Data(password.utf8)
        var add = base(email)
        add[kSecValueData as String] = data
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base(email) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func load(email: String) throws -> String? {
        var q = base(email)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func loadAccount() throws -> Credentials? {
        var q = base(nil)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let dict = out as? [String: Any] else { throw KeychainError(status: status) }
        guard let email = dict[kSecAttrAccount as String] as? String, let data = dict[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return Credentials(email: email, password: password)
    }

    public func delete(email: String) throws {
        let status = SecItemDelete(base(email) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
