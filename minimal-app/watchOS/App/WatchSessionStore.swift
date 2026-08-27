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

    func load(profileID: UUID) -> StremioSession? {
        load(account: account(for: profileID), simulatorURL: simulatorSessionURL(profileID: profileID))
    }

    func loadLegacy() -> StremioSession? {
        load(account: legacyAccount, simulatorURL: legacySimulatorSessionURL)
    }

    private func load(account: String, simulatorURL: URL) -> StremioSession? {
#if targetEnvironment(simulator)
        guard let data = try? Data(contentsOf: simulatorURL) else { return nil }
        return try? JSONDecoder().decode(StremioSession.self, from: data)
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(StremioSession.self, from: data)
#endif
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
        SecItemDelete(key as CFDictionary)
        var insert = key
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
#endif
    }

    func clear(profileID: UUID) {
        clear(
            account: account(for: profileID),
            simulatorURL: simulatorSessionURL(profileID: profileID)
        )
    }

    func clearLegacy() {
        clear(account: legacyAccount, simulatorURL: legacySimulatorSessionURL)
    }

    private func clear(account: String, simulatorURL: URL) {
#if targetEnvironment(simulator)
        try? FileManager.default.removeItem(at: simulatorURL)
#else
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
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

    func load(scope: String) -> [URL]? {
#if targetEnvironment(simulator)
        guard let data = try? Data(contentsOf: simulatorURL(scope: scope)) else {
            return nil
        }
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
#endif
        guard let values = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return values.compactMap(URL.init(string:))
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
        SecItemDelete(key as CFDictionary)
        var insert = key
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
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
