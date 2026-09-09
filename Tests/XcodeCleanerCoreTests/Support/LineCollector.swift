import Foundation

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] { lock.withLock { storage } }

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }

    func contains(_ fragment: String) -> Bool {
        lines.contains { $0.contains(fragment) }
    }
}
