import Foundation
import Security

/// Stores configured add-on URLs outside UserDefaults because Stremio-style
/// manifest URLs can contain private configuration tokens in their path or query.
struct AddonURLStore {
    private let service = "local.stremio.skeleton.addon-urls"
    private let account = "installed-addon-urls"

    func load() -> [URL]? {
        #if targetEnvironment(simulator)
        guard let data = try? Data(contentsOf: simulatorURL) else { return nil }
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
        #endif
        guard let values = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return values.compactMap(URL.init(string:))
    }

    func save(_ urls: [URL]) throws {
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

    #if targetEnvironment(simulator)
    private var simulatorURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("addon-urls.json", isDirectory: false)
    }
    #endif
}
