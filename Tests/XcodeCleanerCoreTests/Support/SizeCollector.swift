import Foundation

/// Thread-safe sink for `Scanner.measureSizes`, whose callback arrives from a task group.
final class SizeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int64] = [:]
    private var order: [String] = []
    private var calls = 0

    var sizes: [String: Int64] { lock.withLock { storage } }
    /// Distinct ids, in the order they first arrived.
    var reportedIDs: [String] { lock.withLock { order } }
    /// Every callback, a repeated id included. `reportedIDs` de-duplicates, so this is what a test
    /// has to compare it against to prove nothing was measured or reported twice.
    var callCount: Int { lock.withLock { calls } }

    func record(_ id: String, _ bytes: Int64) {
        lock.withLock {
            calls += 1
            if storage.updateValue(bytes, forKey: id) == nil {
                order.append(id)
            }
        }
    }

    subscript(id: String) -> Int64? { sizes[id] }
}
