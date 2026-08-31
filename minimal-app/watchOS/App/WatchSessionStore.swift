import CryptoKit
import Foundation
import Security

struct WatchSessionStore {
    private let service = "local.stremio.skeleton.watchkitapp"
    private let legacyAccount = "stremio-session"

    static var storageDescription: String {
#if targetEnvironment(simulator)
        "Session token stored in protected Simulator storage"
#else
        "Session token stored in Keychain"
#endif
    }

    func load(profileID: UUID) throws -> StremioSession? {
        try load(
            account: account(for: profileID),
            simulatorURL: simulatorSessionURL(profileID: profileID)
        )
    }

    func loadLegacy() throws -> StremioSession? {
        try load(account: legacyAccount, simulatorURL: legacySimulatorSessionURL)
    }

    private func load(account: String, simulatorURL: URL) throws -> StremioSession? {
#if targetEnvironment(simulator)
        guard FileManager.default.fileExists(atPath: simulatorURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: simulatorURL)
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data else {
            throw CocoaError(.fileReadCorruptFile)
        }
#endif
        return try JSONDecoder().decode(StremioSession.self, from: data)
    }

    func save(_ session: StremioSession, profileID: UUID) throws {
        try save(
            session,
            account: account(for: profileID),
            simulatorURL: simulatorSessionURL(profileID: profileID)
        )
    }

    private func save(
        _ session: StremioSession,
        account: String,
        simulatorURL: URL
    ) throws {
        let data = try JSONEncoder().encode(session)
#if targetEnvironment(simulator)
        try FileManager.default.createDirectory(
            at: simulatorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(
            to: simulatorURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
#else
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecureStoreWritePolicy.updateOrAdd(
            successStatus: errSecSuccess,
            itemNotFoundStatus: errSecItemNotFound,
            duplicateItemStatus: errSecDuplicateItem,
            update: {
                SecItemUpdate(
                    key as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
            },
            add: {
                var insert = key
                insert[kSecValueData as String] = data
                insert[kSecAttrAccessible as String] =
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                return SecItemAdd(insert as CFDictionary, nil)
            }
        )
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
#endif
    }

    func clear(profileID: UUID) throws {
        try clear(
            account: account(for: profileID),
            simulatorURL: simulatorSessionURL(profileID: profileID)
        )
    }

    func clearLegacy() throws {
        try clear(account: legacyAccount, simulatorURL: legacySimulatorSessionURL)
    }

    private func clear(account: String, simulatorURL: URL) throws {
#if targetEnvironment(simulator)
        guard FileManager.default.fileExists(atPath: simulatorURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: simulatorURL)
#else
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
#endif
    }

    private func account(for profileID: UUID) -> String {
        "stremio-session-profile-\(profileID.uuidString.lowercased())"
    }

#if targetEnvironment(simulator)
    private func simulatorSessionURL(profileID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                "watch-session-profile-\(profileID.uuidString.lowercased()).json",
                isDirectory: false
            )
    }

    private var legacySimulatorSessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-session.json", isDirectory: false)
    }
#else
    private func simulatorSessionURL(profileID: UUID) -> URL {
        URL(fileURLWithPath: "/watch-session-\(profileID.uuidString).unused")
    }

    private var legacySimulatorSessionURL: URL {
        URL(fileURLWithPath: "/watch-session-legacy.unused")
    }
#endif
}

struct WatchAddonURLStore {
    private let service = "local.stremio.skeleton.watchkitapp.addon-urls"

    func load(scope: String) throws -> [URL]? {
#if targetEnvironment(simulator)
        let source = simulatorURL(scope: scope)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return nil
        }
        let data = try Data(contentsOf: source)
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = result as? Data else {
            throw CocoaError(.fileReadCorruptFile)
        }
#endif
        let values = try JSONDecoder().decode([String].self, from: data)
        return try values.map { value in
            guard let url = URL(string: value),
                  (try? AddonEndpoint(manifestURL: url)) != nil
            else { throw CocoaError(.fileReadCorruptFile) }
            return url
        }
    }

    func save(_ urls: [URL], scope: String) throws {
        let data = try JSONEncoder().encode(urls.map(\.absoluteString))
#if targetEnvironment(simulator)
        let destination = simulatorURL(scope: scope)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(
            to: destination,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
#else
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
        ]
        let status = SecureStoreWritePolicy.updateOrAdd(
            successStatus: errSecSuccess,
            itemNotFoundStatus: errSecItemNotFound,
            duplicateItemStatus: errSecDuplicateItem,
            update: {
                SecItemUpdate(
                    key as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
            },
            add: {
                var insert = key
                insert[kSecValueData as String] = data
                insert[kSecAttrAccessible as String] =
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                return SecItemAdd(insert as CFDictionary, nil)
            }
        )
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
#endif
    }

#if targetEnvironment(simulator)
    private func simulatorURL(scope: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-addon-urls-\(scope).json", isDirectory: false)
    }
#endif
}

enum WatchAccountScope {
    static let anonymous = "anonymous"

    static func identifier(for session: StremioSession) -> String {
        let identity = session.user.id
            ?? session.user.email?.lowercased()
            ?? session.authKey
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
