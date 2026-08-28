import Foundation

/// Performs a non-destructive Keychain-style write without depending on the
/// Security framework, which keeps the status transitions unit-testable.
public enum SecureStoreWritePolicy {
    public static func updateOrAdd(
        successStatus: Int32,
        itemNotFoundStatus: Int32,
        duplicateItemStatus: Int32,
        update: () -> Int32,
        add: () -> Int32
    ) -> Int32 {
        let updateStatus = update()
        if updateStatus == successStatus {
            return successStatus
        }
        guard updateStatus == itemNotFoundStatus else {
            return updateStatus
        }

        let addStatus = add()
        if addStatus == duplicateItemStatus {
            // Another writer may have inserted the item between our update
            // and add. Updating once more preserves the latest valid item and
            // avoids a destructive delete/recreate cycle.
            return update()
        }
        return addStatus
    }
}

public enum SecureStoreMigrationPolicy {
    public static func migrateIfPresent(
        _ isPresent: Bool,
        save: () throws -> Void,
        removeLegacyValue: () -> Void
    ) throws {
        guard isPresent else { return }
        try save()
        removeLegacyValue()
    }
}
