import Foundation

/// Thread-safe sink for `Scanner.measureSizes`, whose callback arrives from a task group.
final class SizeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int64] = [:]
    private var order: [String] = []

    var sizes: [String: Int64] { lock.withLock { storage } }
    var reportedIDs: [String] { lock.withLock { order } }

    func record(_ id: String, _ bytes: Int64) {
        lock.withLock {
            if storage.updateValue(bytes, forKey: id) == nil {
                order.append(id)
            }
        }
    }

    subscript(id: String) -> Int64? { sizes[id] }
}
