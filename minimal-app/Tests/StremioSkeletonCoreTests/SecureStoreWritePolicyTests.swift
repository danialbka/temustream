import XCTest
@testable import StremioSkeletonCore

final class SecureStoreWritePolicyTests: XCTestCase {
    private let success: Int32 = 0
    private let notFound: Int32 = -2_530
    private let duplicate: Int32 = -2_529

    func testUpdateSuccessDoesNotAdd() {
        var updates = 0
        var adds = 0
        let status = write(
            update: {
                updates += 1
                return self.success
            },
            add: {
                adds += 1
                return self.success
            }
        )

        XCTAssertEqual(status, success)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(adds, 0)
    }

    func testMissingItemIsAdded() {
        var updates = 0
        var adds = 0
        let status = write(
            update: {
                updates += 1
                return self.notFound
            },
            add: {
                adds += 1
                return self.success
            }
        )

        XCTAssertEqual(status, success)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(adds, 1)
    }

    func testUpdateFailureReturnsWithoutAdding() {
        let failure: Int32 = -2_524
        var adds = 0
        let status = write(
            update: { failure },
            add: {
                adds += 1
                return self.success
            }
        )

        XCTAssertEqual(status, failure)
        XCTAssertEqual(adds, 0)
    }

    func testAddFailureIsReturned() {
        let failure: Int32 = -50
        let status = write(update: { self.notFound }, add: { failure })

        XCTAssertEqual(status, failure)
    }

    func testDuplicateAddRetriesUpdateOnce() {
        var updateStatuses = [notFound, success]
        var adds = 0
        let status = write(
            update: { updateStatuses.removeFirst() },
            add: {
                adds += 1
                return self.duplicate
            }
        )

        XCTAssertEqual(status, success)
        XCTAssertTrue(updateStatuses.isEmpty)
        XCTAssertEqual(adds, 1)
    }

    func testMigrationFailureRetainsLegacyValue() {
        struct Failure: Error {}
        var removed = false

        XCTAssertThrowsError(
            try SecureStoreMigrationPolicy.migrateIfPresent(
                true,
                save: { throw Failure() },
                removeLegacyValue: { removed = true }
            )
        )
        XCTAssertFalse(removed)
    }

    func testMigrationSuccessRemovesLegacyValue() throws {
        var saved = false
        var removed = false

        try SecureStoreMigrationPolicy.migrateIfPresent(
            true,
            save: { saved = true },
            removeLegacyValue: { removed = true }
        )

        XCTAssertTrue(saved)
        XCTAssertTrue(removed)
    }

    func testMigrationTransactionKeepsDiscoveryMarkerUntilEveryWriteSucceeds() {
        struct Failure: Error {}
        var sessionSaved = false
        var addonsSaved = false
        var legacyDiscoveryPresent = true

        XCTAssertThrowsError(
            try SecureStoreMigrationPolicy.migrateTransactionIfPresent(
                legacyDiscoveryPresent,
                persistAllDependencies: {
                    sessionSaved = true
                    throw Failure()
                },
                clearLegacyDiscovery: {
                    legacyDiscoveryPresent = false
                }
            )
        )
        XCTAssertTrue(sessionSaved)
        XCTAssertFalse(addonsSaved)
        XCTAssertTrue(legacyDiscoveryPresent)

        XCTAssertNoThrow(
            try SecureStoreMigrationPolicy.migrateTransactionIfPresent(
                legacyDiscoveryPresent,
                persistAllDependencies: {
                    sessionSaved = true
                    addonsSaved = true
                },
                clearLegacyDiscovery: {
                    legacyDiscoveryPresent = false
                }
            )
        )
        XCTAssertTrue(sessionSaved)
        XCTAssertTrue(addonsSaved)
        XCTAssertFalse(legacyDiscoveryPresent)
    }

    private func write(
        update: () -> Int32,
        add: () -> Int32
    ) -> Int32 {
        SecureStoreWritePolicy.updateOrAdd(
            successStatus: success,
            itemNotFoundStatus: notFound,
            duplicateItemStatus: duplicate,
            update: update,
            add: add
        )
    }
}
