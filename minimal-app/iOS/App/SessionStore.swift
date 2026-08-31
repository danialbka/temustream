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

    func load() throws -> StremioSession? {
#if targetEnvironment(simulator)
        guard FileManager.default.fileExists(atPath: simulatorSessionURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: simulatorSessionURL)
        return try JSONDecoder().decode(StremioSession.self, from: data)
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
        return try JSONDecoder().decode(StremioSession.self, from: data)
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

    func clear() throws {
#if targetEnvironment(simulator)
        guard FileManager.default.fileExists(atPath: simulatorSessionURL.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: simulatorSessionURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Another process may have removed it after the existence check.
            return
        }
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

#if targetEnvironment(simulator)
    private var simulatorSessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("session.json", isDirectory: false)
    }
#endif
}
