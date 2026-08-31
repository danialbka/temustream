import Foundation
import XCTest
@testable import StremioSkeletonCore

private actor OwnershipSuspensionGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class AccountStateOwnershipTests: XCTestCase {
    func testAccountStorageScopeRestoresAnonymousNamespaceAfterSignOut() {
        let profileID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let first = StremioSession(
            authKey: "first-key",
            user: StremioUser(id: "user-a", email: "a@example.test")
        )
        let refreshedFirst = StremioSession(
            authKey: "refreshed-key",
            user: StremioUser(id: "user-a", email: "a@example.test")
        )
        let second = StremioSession(
            authKey: "second-key",
            user: StremioUser(id: "user-b", email: "b@example.test")
        )

        let anonymous = AccountStorageScope.storageScope(
            profileID: profileID,
            session: nil
        )
        let firstAccount = AccountStorageScope.storageScope(
            profileID: profileID,
            session: first
        )

        XCTAssertEqual(
            firstAccount,
            AccountStorageScope.storageScope(
                profileID: profileID,
                session: refreshedFirst
            ),
            "Refreshing a token must not orphan the same account's durable state."
        )
        XCTAssertNotEqual(anonymous, firstAccount)
        XCTAssertNotEqual(
            firstAccount,
            AccountStorageScope.storageScope(profileID: profileID, session: second)
        )
        XCTAssertEqual(
            anonymous,
            AccountStorageScope.storageScope(profileID: profileID, session: nil),
            "Sign-out must return to the preserved anonymous namespace."
        )
        XCTAssertEqual(
            AccountStorageScope.libraryFileName(for: nil),
            ViewingProfileDataFile.anonymousLibrary
        )
        XCTAssertNotEqual(
            AccountStorageScope.libraryFileName(for: first),
            AccountStorageScope.libraryFileName(for: second)
        )

        let anonymousAddon = URL(string: "https://anonymous.example/manifest.json")!
        let accountAddon = URL(string: "https://account.example/manifest.json")!
        let stateByScope = [
            anonymous: [anonymousAddon],
            firstAccount: [accountAddon],
        ]
        XCTAssertEqual(stateByScope[firstAccount], [accountAddon])
        XCTAssertEqual(
            stateByScope[AccountStorageScope.storageScope(
                profileID: profileID,
                session: nil
            )],
            [anonymousAddon],
            "Signing out must reveal the preserved anonymous state, not the account snapshot."
        )
    }

    func testIdentityLessLoginUsesSubmittedEmailAcrossTokenRefresh() {
        let firstResponse = StremioSession(
            authKey: "rotating-token-one",
            user: StremioUser(id: nil, email: nil)
        )
        let secondResponse = StremioSession(
            authKey: "rotating-token-two",
            user: StremioUser(id: nil, email: nil)
        )
        let first = AccountStorageScope.sessionEnsuringStableIdentity(
            firstResponse,
            submittedEmail: " Person@Example.Test "
        )
        let second = AccountStorageScope.sessionEnsuringStableIdentity(
            secondResponse,
            submittedEmail: "person@example.test"
        )

        XCTAssertEqual(first.user.email, "Person@Example.Test")
        XCTAssertEqual(second.user.email, "person@example.test")
        XCTAssertEqual(
            AccountStorageScope.accountIdentifier(for: first),
            AccountStorageScope.accountIdentifier(for: second),
            "A refreshed auth token must not move the same submitted account into a new durable namespace."
        )
    }

    func testOnlyLatestOperationOwnsPublicationAfterSuspension() async {
        let gate = OwnershipSuspensionGate()
        var owner = LatestOperationOwner()
        let slowToken = owner.begin()
        let slow = Task {
            await gate.suspend()
            return slowToken
        }
        await gate.waitUntilEntered()

        let fastToken = owner.begin()
        var publishedValue = "fast"
        var latestIsLoading = true
        XCTAssertTrue(owner.owns(fastToken))
        XCTAssertFalse(owner.owns(slowToken))

        await gate.release()
        let resumedSlowToken = await slow.value
        if owner.owns(resumedSlowToken) {
            publishedValue = "slow"
            latestIsLoading = false
        }
        XCTAssertFalse(
            owner.owns(resumedSlowToken),
            "A stale operation must not publish results or clear latest loading state."
        )
        XCTAssertEqual(publishedValue, "fast")
        XCTAssertTrue(latestIsLoading)

        if owner.owns(fastToken) {
            latestIsLoading = false
        }
        XCTAssertFalse(latestIsLoading)

        owner.invalidate()
        XCTAssertFalse(
            owner.owns(fastToken),
            "Retry/item replacement must invalidate an in-flight media-selection load."
        )
    }
}
