import Foundation
import Security

/// Stores configured add-on URLs outside UserDefaults because Stremio-style
/// manifest URLs can contain private configuration tokens in their path or query.
struct AddonURLStore {
    private let service = "local.stremio.skeleton.addon-urls"
    private let legacyAccount = "installed-addon-urls"

    func load() throws -> [URL]? {
        try load(account: legacyAccount, simulatorURL: legacySimulatorURL)
    }

    func load(scope: String) throws -> [URL]? {
        try load(
            account: account(for: scope),
            simulatorURL: simulatorURL(scope: scope)
        )
    }

    private func load(account: String, simulatorURL: URL) throws -> [URL]? {
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
        let values = try JSONDecoder().decode([String].self, from: data)
        return try values.map { value in
            guard let url = URL(string: value),
                  (try? AddonEndpoint(manifestURL: url)) != nil
            else { throw CocoaError(.fileReadCorruptFile) }
            return url
        }
    }

    func save(_ urls: [URL]) throws {
        try save(
            urls,
            account: legacyAccount,
            simulatorURL: legacySimulatorURL
        )
    }

    func save(_ urls: [URL], scope: String) throws {
        try save(
            urls,
            account: account(for: scope),
            simulatorURL: simulatorURL(scope: scope)
        )
    }

    private func save(
        _ urls: [URL],
        account: String,
        simulatorURL: URL
    ) throws {
        let data = try JSONEncoder().encode(urls.map(\.absoluteString))
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

    func clearLegacy() throws {
        try clear(account: legacyAccount, simulatorURL: legacySimulatorURL)
    }

    private func clear(account: String, simulatorURL: URL) throws {
        #if targetEnvironment(simulator)
        guard FileManager.default.fileExists(atPath: simulatorURL.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: simulatorURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
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

    private func account(for scope: String) -> String {
        "installed-addon-urls-\(scope)"
    }

    #if targetEnvironment(simulator)
    private var storageDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    }

    private var legacySimulatorURL: URL {
        storageDirectory.appendingPathComponent("addon-urls.json", isDirectory: false)
    }

    private func simulatorURL(scope: String) -> URL {
        storageDirectory.appendingPathComponent(
            "addon-urls-\(scope).json",
            isDirectory: false
        )
    }
    #else
    private var legacySimulatorURL: URL {
        URL(fileURLWithPath: "/addon-urls-legacy.unused")
    }

    private func simulatorURL(scope: String) -> URL {
        URL(fileURLWithPath: "/addon-urls-\(scope).unused")
    }
    #endif
}
