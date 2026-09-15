import Foundation
import XcodeCleanerCore

/// Thread-safe sink for `Scanner.discoverProjectCaches`, whose callback arrives from a task group.
final class ItemCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CleanupItem] = []

    /// Every item, in the order it was reported.
    var items: [CleanupItem] { lock.withLock { storage } }

    func record(_ item: CleanupItem) {
        lock.withLock { storage.append(item) }
    }
}
