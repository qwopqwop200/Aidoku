// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation
import Security

protocol TranslationCredentialProviding: Sendable {
    /// This method is intentionally unavailable to UI code through the settings
    /// surface. The HTTP client reads the secret only at request time.
    func secret(for account: String) throws -> String
}

protocol TranslationCredentialManaging:
    TranslationCredentialProviding, Sendable
{
    func save(_ secret: String, for account: String) throws
    func containsSecret(for account: String) throws -> Bool
    func deleteSecret(for account: String) throws
}

enum TranslationKeychainAccessGroupResolver {
    static let infoPlistKey = "AidokuTranslationKeychainAccessGroup"

    static func resolve(_ rawValue: Any?) -> String? {
        guard let value = rawValue as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              trimmed.utf8.count <= 256,
              !trimmed.contains("$("),
              !trimmed.contains("${"),
              !trimmed.unicodeScalars.contains(
                  where: CharacterSet.controlCharacters.contains
              )
        else {
            return nil
        }
        return trimmed
    }

    static func resolve(from bundle: Bundle = .main) -> String? {
        resolve(bundle.object(forInfoDictionaryKey: infoPlistKey))
    }
}

enum TranslationCredentialStoreError: Error, Equatable, LocalizedError {
    case invalidAccount
    case invalidSecret
    case notFound
    case invalidEncoding
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAccount:
            return "The credential account is invalid."
        case .invalidSecret:
            return "The API key is blank, too large, or contains unsafe characters."
        case .notFound:
            return "No API key is saved for this provider."
        case .invalidEncoding:
            return "The saved API key has an invalid encoding."
        case let .keychainStatus(status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

struct KeychainTranslationCredentialStore:
    TranslationCredentialManaging, Sendable
{
    static let maximumSecretBytes = 16 * 1024

    let service: String
    let accessGroup: String?

    init(
        service: String = "app.aidoku.translation",
        accessGroup: String? = TranslationKeychainAccessGroupResolver.resolve()
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func save(_ secret: String, for account: String) throws {
        try validateAccount(account)
        guard secret == secret.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty,
              secret.utf8.count <= Self.maximumSecretBytes,
              !secret.contains("\r"),
              !secret.contains("\n"),
              !secret.contains("\0")
        else {
            throw TranslationCredentialStoreError.invalidSecret
        }

        let secretData = Data(secret.utf8)
        let query = baseQuery(for: account)
        let attributes: [String: Any] = [
            kSecValueData as String: secretData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw TranslationCredentialStoreError.keychainStatus(updateStatus)
        }

        var addition = query
        attributes.forEach { addition[$0.key] = $0.value }
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw TranslationCredentialStoreError.keychainStatus(retryStatus)
            }
            return
        }
        throw TranslationCredentialStoreError.keychainStatus(addStatus)
    }

    func secret(for account: String) throws -> String {
        try validateAccount(account)
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw TranslationCredentialStoreError.notFound
        }
        guard status == errSecSuccess else {
            throw TranslationCredentialStoreError.keychainStatus(status)
        }
        guard let data = result as? Data,
              let secret = String(data: data, encoding: .utf8)
        else {
            throw TranslationCredentialStoreError.invalidEncoding
        }
        guard secret.utf8.count <= Self.maximumSecretBytes,
              !secret.isEmpty,
              !secret.contains("\r"),
              !secret.contains("\n"),
              !secret.contains("\0")
        else {
            throw TranslationCredentialStoreError.invalidSecret
        }
        return secret
    }

    func containsSecret(for account: String) throws -> Bool {
        try validateAccount(account)
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = kCFBooleanFalse
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw TranslationCredentialStoreError.keychainStatus(status)
        }
    }

    func deleteSecret(for account: String) throws {
        try validateAccount(account)
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TranslationCredentialStoreError.keychainStatus(status)
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func validateAccount(_ account: String) throws {
        guard account == account.trimmingCharacters(in: .whitespacesAndNewlines),
              !account.isEmpty,
              account.utf8.count <= 256,
              !account.unicodeScalars.contains(
                  where: CharacterSet.controlCharacters.contains
              )
        else {
            throw TranslationCredentialStoreError.invalidAccount
        }
    }
}
