import Foundation
import Observation
import XcodeCleanerCore

struct ConfirmEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let sizeBytes: Int64?
    let isDestructive: Bool
}

struct Confirmation: Identifiable {
    enum Kind {
        case cleanup
        case deleteMounts
    }

    let id = UUID()
    let kind: Kind
    let entries: [ConfirmEntry]

    var totalBytes: Int64 { entries.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
    var hasDestructive: Bool { entries.contains(where: \.isDestructive) }

    var title: String {
        switch kind {
        case .cleanup: "Очистить Xcode"
        case .deleteMounts: "Удалить маунты Arcadia"
        }
    }
}

/// One measured size on its way from a background walk to the list.
private struct SizeUpdate: Sendable {
    let id: String
    let bytes: Int64
}

@MainActor
@Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case xcode
        case arcadia
        case log

        var id: String { rawValue }

        var title: String {
            switch self {
            case .xcode: "Xcode"
            case .arcadia: "Arcadia"
            case .log: "Журнал"
            }
        }

        var systemImage: String {
            switch self {
            case .xcode: "hammer"
            case .arcadia: "externaldrive"
            case .log: "doc.text"
            }
        }
    }

    var section: Section = .xcode
    var scan = ScanResult()
    var isScanning = false
    var isWorking = false
    var isMeasuring = false
    /// Sizes that arrived after the scan, keyed by `CleanupItem.id` or `ArcMountInfo.id`.
    var sizes: [String: Int64] = [:]
    var selectedItemIDs: Set<String> = []
    var expandedKinds: Set<CleanupKind> = []
    var simulatorMode: SimulatorMode = .deleteUnavailable
    var archiveMaxAgeDays = 30
    var selectedMountIDs: Set<String> = []
    var logLines: [String] = []
    var lastReport: CleanupReport?
    /// Whether the header still shows the result of the last cleanup instead of the pending total.
    var showsLastResult = false
    var errorMessage: String?
    var pendingConfirmation: Confirmation?
    var unmountRetryPath: String?

    private let runner: any CommandRunning
    private let cachePaths: CachePaths
    private let scanner: XcodeCleanerCore.Scanner
    private let mountManager: ArcMountManager
    private var logFile: CleanupLogFile?
    private var hasPreselected = false
    private var measureTask: Task<Void, Never>?
    /// Bumped whenever measuring is restarted, so a batch from an abandoned run is discarded
    /// instead of landing on top of a fresh scan.
    private var measureGeneration = 0

    init(runner: any CommandRunning = ProcessCommandRunner(), cachePaths: CachePaths = CachePaths()) {
        self.runner = runner
        self.cachePaths = cachePaths
        scanner = XcodeCleanerCore.Scanner(runner: runner, cachePaths: cachePaths)
        mountManager = ArcMountManager(runner: runner, home: cachePaths.home)
    }

    // MARK: Items

    var items: [CleanupItem] {
        var all = scan.cacheItems + scan.projectCacheItems
        if let simulators = scan.simulators {
            all.append(simulators.makeItem(mode: simulatorMode))
        }
        all += ArchiveScanner.olderThan(days: archiveMaxAgeDays, scan.archives).map { $0.makeItem() }
        all += scan.xcodes.filter { $0.isActive == false }.map { $0.makeItem() }
        all += scan.toolchains.filter { $0.isProtected == false }.map { $0.makeItem() }
        return all
    }

    func items(for kind: CleanupKind) -> [CleanupItem] {
        items.filter { $0.kind == kind }
    }

    /// The categories worth a row in a group: execution order, minus everything empty.
    func kinds(in group: CleanupGroup) -> [CleanupKind] {
        CleanupKind.executionOrder.filter { $0.group == group && items(for: $0).isEmpty == false }
    }

    var selectedItems: [CleanupItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    var sortedMounts: [ArcMountInfo] {
        scan.mounts.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain {
                return lhs.isMain
            }
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case let (left?, right?):
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.mount.name.localizedStandardCompare(rhs.mount.name) == .orderedAscending
            }
        }
    }

    var selectedMounts: [ArcMountInfo] {
        scan.mounts.filter { selectedMountIDs.contains($0.id) && $0.isMain == false }
    }

    // MARK: Sizes

    func size(of item: CleanupItem) -> Int64? {
        item.sizeBytes ?? sizes[item.id]
    }

    func size(of mount: ArcMountInfo) -> Int64? {
        mount.storeSizeBytes ?? sizes[mount.id]
    }

    /// The part of a category that is already measured. Pair it with `hasPendingSizes(_:)`: while
    /// that is true the number is still growing.
    func knownBytes(for kind: CleanupKind) -> Int64 {
        items(for: kind).reduce(0) { $0 + (size(of: $1) ?? 0) }
    }

    func hasPendingSizes(for kind: CleanupKind) -> Bool {
        items(for: kind).contains { size(of: $0) == nil }
    }

    var xcodeBytesToFree: Int64 {
        selectedItems.reduce(0) { $0 + (size(of: $1) ?? 0) }
    }

    var arcadiaBytesToFree: Int64 {
        selectedMounts.reduce(0) { $0 + (size(of: $1) ?? 0) }
    }

    // MARK: Selection

    func isSelected(_ item: CleanupItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    func toggle(_ item: CleanupItem) {
        selectionChanged()
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func setSelected(kind: CleanupKind, _ selected: Bool) {
        selectionChanged()
        let ids = items(for: kind).map(\.id)
        if selected {
            selectedItemIDs.formUnion(ids)
        } else {
            selectedItemIDs.subtract(ids)
        }
    }

    func isGroupSelected(_ kind: CleanupKind) -> Bool {
        let group = items(for: kind)
        return group.isEmpty == false && group.allSatisfy { selectedItemIDs.contains($0.id) }
    }

    func isSelected(_ mount: ArcMountInfo) -> Bool {
        mount.isMain == false && selectedMountIDs.contains(mount.id)
    }

    func setSelected(_ mount: ArcMountInfo, _ selected: Bool) {
        guard mount.isMain == false else { return }
        selectionChanged()
        if selected {
            selectedMountIDs.insert(mount.id)
        } else {
            selectedMountIDs.remove(mount.id)
        }
    }

    func isExpanded(_ kind: CleanupKind) -> Bool {
        expandedKinds.contains(kind)
    }

    func toggleExpanded(_ kind: CleanupKind) {
        if expandedKinds.contains(kind) {
            expandedKinds.remove(kind)
        } else {
            expandedKinds.insert(kind)
        }
    }

    private func selectionChanged() {
        showsLastResult = false
    }

    // MARK: Scan

    func rescan() async {
        guard isScanning == false else { return }
        isScanning = true
        cancelMeasuring()
        sizes = [:]
        defer { isScanning = false }
        scan = await scanner.scan()
        let validIDs = Set(items.map(\.id))
        selectedItemIDs.formIntersection(validIDs)
        selectedMountIDs.formIntersection(Set(scan.mounts.map(\.id)))
        // The first scan of a session arrives at an empty selection, so it starts the user on the
        // safe default — the categories that regenerate by themselves — instead of nothing at all.
        // Later scans respect whatever the user picked.
        if hasPreselected == false {
            hasPreselected = true
            selectedItemIDs.formUnion(
                items.filter { $0.kind.group == .safe && $0.isDestructive == false }.map(\.id)
            )
        }
        for warning in scan.warnings {
            log("⚠︎ \(warning)")
        }
        startMeasuring(scan)
    }

    /// Walks everything the scan left unmeasured and feeds the numbers back in batches: a size
    /// arrives every few hundred milliseconds for half a minute, and applying each one on its own
    /// would rebuild the list that many times.
    private func startMeasuring(_ result: ScanResult) {
        measureTask?.cancel()
        measureGeneration += 1
        let generation = measureGeneration
        let scanner = scanner
        isMeasuring = true
        measureTask = Task { @MainActor [weak self] in
            let (stream, continuation) = AsyncStream.makeStream(of: SizeUpdate.self)
            async let production: Void = AppModel.measure(result, scanner: scanner, into: continuation)
            var pending: [String: Int64] = [:]
            var lastFlush = ContinuousClock.now
            for await update in stream {
                pending[update.id] = update.bytes
                let now = ContinuousClock.now
                guard now - lastFlush >= .milliseconds(150) else { continue }
                lastFlush = now
                self?.apply(pending, generation: generation)
                pending.removeAll(keepingCapacity: true)
            }
            await production
            self?.apply(pending, generation: generation)
            self?.finishMeasuring(generation: generation)
        }
    }

    /// Runs off the main actor so the walks never touch it; every size goes through the stream and
    /// is applied on the main actor by the consumer.
    private nonisolated static func measure(
        _ result: ScanResult,
        scanner: XcodeCleanerCore.Scanner,
        into continuation: AsyncStream<SizeUpdate>.Continuation
    ) async {
        await scanner.measureSizes(for: result) { id, bytes in
            continuation.yield(SizeUpdate(id: id, bytes: bytes))
        }
        continuation.finish()
    }

    private func apply(_ batch: [String: Int64], generation: Int) {
        guard generation == measureGeneration, batch.isEmpty == false else { return }
        sizes.merge(batch) { _, new in new }
    }

    private func finishMeasuring(generation: Int) {
        guard generation == measureGeneration else { return }
        isMeasuring = false
    }

    private func cancelMeasuring() {
        measureTask?.cancel()
        measureTask = nil
        measureGeneration += 1
        isMeasuring = false
    }

    // MARK: Cleanup

    func requestXcodeCleanup() {
        let entries = selectedItems.map {
            ConfirmEntry(
                id: $0.id,
                title: "\($0.kind.title): \($0.title)",
                sizeBytes: size(of: $0),
                isDestructive: $0.isDestructive
            )
        }
        guard entries.isEmpty == false else { return }
        pendingConfirmation = Confirmation(kind: .cleanup, entries: entries)
    }

    func confirmXcodeCleanup() async {
        let items = selectedItems
        pendingConfirmation = nil
        cancelMeasuring()
        await work {
            let cleaner = Cleaner(runner: runner, deleter: scanner.makeDeleter(for: scan), home: cachePaths.home)
            let report = try await cleaner.run(items) { [weak self] line in
                Task { @MainActor in self?.log(line) }
            }
            lastReport = report
            showsLastResult = report.freedBytes != nil
            section = .log
        }
        await rescan()
    }

    // MARK: Arcadia

    func unmountSelected(force: Bool = false) async {
        let mounts = selectedMounts.filter { $0.mount.isMounted }
        unmountRetryPath = nil
        await work {
            for info in mounts {
                do {
                    try await mountManager.unmount(info.mount.mount, force: force) { [weak self] line in
                        Task { @MainActor in self?.log(line) }
                    }
                } catch let error as ArcMountError {
                    if case .commandFailed = error, force == false {
                        unmountRetryPath = info.mount.mount
                    }
                    throw error
                }
            }
        }
        await rescan()
    }

    func retryUnmountWithForce() async {
        guard let path = unmountRetryPath else { return }
        unmountRetryPath = nil
        await work {
            try await mountManager.unmount(path, force: true) { [weak self] line in
                Task { @MainActor in self?.log(line) }
            }
        }
        await rescan()
    }

    func requestMountRemoval() {
        let entries = selectedMounts.map {
            ConfirmEntry(
                id: $0.id,
                title: "Arcadia: \($0.mount.name)",
                sizeBytes: size(of: $0),
                isDestructive: true
            )
        }
        guard entries.isEmpty == false else { return }
        pendingConfirmation = Confirmation(kind: .deleteMounts, entries: entries)
    }

    func confirmMountRemoval() async {
        let mounts = selectedMounts
        pendingConfirmation = nil
        cancelMeasuring()
        await work {
            for info in mounts {
                try await mountManager.remove(info.mount) { [weak self] line in
                    Task { @MainActor in self?.log(line) }
                }
            }
        }
        await rescan()
    }

    // MARK: Helpers

    private func work(_ body: () async throws -> Void) async {
        guard isWorking == false else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await body()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func log(_ line: String) {
        logLines.append(line)
        if logFile == nil {
            logFile = try? CleanupLogFile(directory: CleanupLogFile.defaultDirectory(home: cachePaths.home))
        }
        logFile?.appendLine(line)
    }
}
