import Foundation
import Security

struct SessionStore {
    private let service = "local.stremio.skeleton"
    private let account = "stremio-session"

    static var storageDescription: String {
#if targetEnvironment(simulator)
        "Session token stored in protected Simulator storage"
#else
        "Session token stored in Keychain"
#endif
    }

    func load() -> StremioSession? {
#if targetEnvironment(simulator)
        guard let data = try? Data(contentsOf: simulatorSessionURL) else { return nil }
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

    func save(_ session: StremioSession) throws {
        let data = try JSONEncoder().encode(session)
#if targetEnvironment(simulator)
        try FileManager.default.createDirectory(
            at: simulatorSessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(
            to: simulatorSessionURL,
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

    func clear() {
#if targetEnvironment(simulator)
        try? FileManager.default.removeItem(at: simulatorSessionURL)
#else
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
#endif
    }

#if targetEnvironment(simulator)
    private var simulatorSessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session.json", isDirectory: false)
    }
#endif
}
