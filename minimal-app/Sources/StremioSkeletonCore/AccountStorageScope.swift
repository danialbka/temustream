import CryptoKit
import Foundation

/// Namespaces durable account-synchronized state without exposing a user ID,
/// email address, or authentication key in a filename or Keychain account.
public enum AccountStorageScope {
    public static let anonymous = "anonymous"

    /// Stremio login responses normally include a stable user ID or email, but
    /// older/self-hosted endpoints can return only a rotating auth token. Keep
    /// the submitted identity in that case so token refresh cannot silently
    /// move the account's library and add-ons into a new namespace.
    public static func sessionEnsuringStableIdentity(
        _ session: StremioSession,
        submittedEmail: String
    ) -> StremioSession {
        let stableID = normalized(session.user.id)
        let stableEmail = normalized(session.user.email)
            ?? normalized(submittedEmail)
        return StremioSession(
            authKey: session.authKey,
            user: StremioUser(id: stableID, email: stableEmail)
        )
    }

    public static func accountIdentifier(for session: StremioSession) -> String {
        let identity: String
        if let userID = normalized(session.user.id) {
            identity = "id:\(userID)"
        } else if let email = normalized(session.user.email)?.lowercased() {
            identity = "email:\(email)"
        } else {
            identity = "auth:\(session.authKey)"
        }
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static func storageScope(
        profileID: UUID,
        session: StremioSession?
    ) -> String {
        let profile = profileID.uuidString.lowercased()
        guard let session else { return "profile-\(profile)-\(anonymous)" }
        return "profile-\(profile)-account-\(accountIdentifier(for: session))"
    }

    public static func libraryFileName(for session: StremioSession?) -> String {
        guard let session else { return ViewingProfileDataFile.anonymousLibrary }
        return "library-account-\(accountIdentifier(for: session)).json"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
