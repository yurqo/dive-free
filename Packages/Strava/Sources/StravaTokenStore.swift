import Foundation
import Security

/// Secure storage for Strava tokens. Abstracted so the auth manager can be
/// tested against an in-memory store instead of the real Keychain.
public protocol StravaTokenStore: Sendable {
    func load() -> StravaTokens?
    func save(_ tokens: StravaTokens) throws
    func clear() throws
}

/// Keychain-backed token store. Tokens are JSON-encoded into a single generic
/// password item — never UserDefaults, which is unencrypted.
public struct KeychainTokenStore: StravaTokenStore {
    private let service: String
    private let account: String

    public init(service: String = "org.yurko.divefree.strava", account: String = "tokens") {
        self.service = service
        self.account = account
    }

    public enum KeychainError: Error, Sendable {
        case unexpectedStatus(OSStatus)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> StravaTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StravaTokens.self, from: data)
    }

    public func save(_ tokens: StravaTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        // Upsert: try to update an existing item, otherwise add a new one.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// In-memory store for previews and unit tests.
public final class InMemoryTokenStore: StravaTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: StravaTokens?

    public init(tokens: StravaTokens? = nil) {
        self.tokens = tokens
    }

    public func load() -> StravaTokens? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: StravaTokens) throws {
        lock.lock(); defer { lock.unlock() }
        self.tokens = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
    }
}
