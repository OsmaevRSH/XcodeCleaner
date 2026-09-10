import Foundation
import Observation
import XcodeCleanerCore

struct ConfirmEntry: Identifiable, Hashable {
    let id: String
    /// The category the entry came from, or nil for an Arcadia mount, which has none.
    let kind: CleanupKind?
    let title: String
    let sizeBytes: Int64?
    let isDestructive: Bool
}

struct Confirmation: Identifiable {
    /// Deletion means different things in the two flows, so every sentence about consequences
    /// hangs off the kind instead of one string trying to cover both.
    enum Kind {
        /// Xcode items: caches are emptied in place, everything else goes to the Trash through
        /// `SafeDeleter.trash`, so it is still there to drag back out.
        case cleanup
        /// Arcadia stores: `removeItem`, which never touches the Trash.
        case deleteMounts

        var title: String {
            switch self {
            case .cleanup: "Очистить Xcode"
            case .deleteMounts: "Удалить маунты Arcadia"
            }
        }

        var acknowledgement: String {
            switch self {
            case .cleanup: "Понимаю, что отмеченные данные уйдут в Корзину и сами не вернутся"
            case .deleteMounts: "Понимаю, что store будут удалены навсегда, мимо Корзины"
            }
        }

        /// What the warning triangle next to an entry means in this flow.
        var destructiveHint: String {
            switch self {
            case .cleanup: "Уйдёт в Корзину, само не вернётся"
            case .deleteMounts: "Удаляется навсегда, мимо Корзины"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let entries: [ConfirmEntry]

    var title: String { kind.title }
    var totalBytes: Int64 { entries.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
    var hasDestructive: Bool { entries.contains(where: \.isDestructive) }

    /// `Cleaner.run` shuts every booted simulator down before it touches simulator storage. The
    /// user hears about that here, not from a simulator disappearing mid-run.
    var shutsDownSimulators: Bool {
        entries.contains { $0.kind == .simulators || $0.kind == .simulatorCaches }
    }
}

/// One measured size on its way from a background walk to the list.
private struct SizeUpdate: Sendable {
    let id: String
    let bytes: Int64
}

/// A log line with an identity of its own. The text repeats — «  simctl delete unavailable» looks
/// the same every run — so `ForEach` cannot key on it, and keying on the index means rebuilding an
/// array of every line on every append.
struct LogEntry: Identifiable, Hashable {
    let id: Int
    let text: String
}

/// Carries every failure of a batch instead of only the first: the run does not stop at the first
/// mount that refused, so the report must not either.
private struct MountBatchError: LocalizedError {
    let messages: [String]

    var errorDescription: String? { messages.joined(separator: "\n") }
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

    var section: Section = .xcode {
        // The retry offer belongs to the unmount the user just watched fail, not to the session.
        didSet { unmountRetryPath = nil }
    }

    var scan = ScanResult() {
        didSet { rebuildItems() }
    }

    var isScanning = false
    var isWorking = false
    var isMeasuring = false
    /// Sizes that arrived after the scan, keyed by `CleanupItem.id` or `ArcMountInfo.id`.
    var sizes: [String: Int64] = [:]
    var selectedItemIDs: Set<String> = []
    var expandedKinds: Set<CleanupKind> = []
    /// Both of these change what is effectively selected, so they clear the last result the same
    /// way ticking a checkbox does — otherwise the header keeps reporting a finished cleanup while
    /// the button already offers a different total.
    var simulatorMode: SimulatorMode = .deleteUnavailable {
        didSet {
            rebuildItems()
            selectionChanged()
        }
    }

    var archiveMaxAgeDays = 30 {
        didSet {
            rebuildItems()
            selectionChanged()
        }
    }

    var selectedMountIDs: Set<String> = []
    private(set) var logEntries: [LogEntry] = []
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
    private var nextLogID = 0
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

    /// Rebuilt only when the scan, the simulator mode or the archive age changes. Every read used
    /// to redo the whole thing — an array build, an archive filter and a string interpolation per
    /// item — and a single render pass asks for it dozens of times.
    private(set) var items: [CleanupItem] = []

    private func rebuildItems() {
        var all = scan.cacheItems + scan.projectCacheItems
        if let simulators = scan.simulators {
            all.append(simulators.makeItem(mode: simulatorMode))
        }
        all += ArchiveScanner.olderThan(days: archiveMaxAgeDays, scan.archives).map { $0.makeItem() }
        all += scan.xcodes.filter { $0.isActive == false }.map { $0.makeItem() }
        all += scan.toolchains.filter { $0.isProtected == false }.map { $0.makeItem() }
        items = all
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

    /// How much of a category is picked, so its header can show the third state a category really
    /// has. With four of five archives picked a two-state checkbox reads as empty, while all four
    /// are still counted and still deleted.
    func selectionState(of kind: CleanupKind) -> (selected: Int, total: Int) {
        let group = items(for: kind)
        return (group.filter { selectedItemIDs.contains($0.id) }.count, group.count)
    }

    /// Picks the whole category, unless it is already whole — then it clears it.
    func toggleGroupSelection(_ kind: CleanupKind) {
        let state = selectionState(of: kind)
        guard state.total > 0 else { return }
        setSelected(kind: kind, state.selected < state.total)
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
        // The offer to retry with --force only means anything while the mount it points at is
        // still mounted; anything else leaves a banner about a mount that is already gone.
        if let path = unmountRetryPath,
           scan.mounts.contains(where: { $0.mount.mount == path && $0.mount.isMounted }) == false {
            unmountRetryPath = nil
        }
        let validIDs = Set(items.map(\.id))
        selectedItemIDs.formIntersection(validIDs)
        selectedMountIDs.formIntersection(Set(scan.mounts.map(\.id)))
        // The first scan of a session arrives at an empty selection, so it starts the user on the
        // safe default — the categories that regenerate by themselves — instead of nothing at all.
        // Later scans respect whatever the user picked.
        if hasPreselected == false {
            hasPreselected = true
            // `.projectCaches` is `.safe` and does come back, but only through a full Tuist and
            // SwiftPM re-resolve in every mount, over the network and the SPM registry. A first run
            // must not arrive already armed to do that, so it stays selectable and stays unpicked.
            selectedItemIDs.formUnion(
                items
                    .filter {
                        $0.kind.group == .safe && $0.isDestructive == false && $0.kind != .projectCaches
                    }
                    .map(\.id)
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
                // Time alone is a leading-edge gate: a size that arrives long after the previous
                // one waits for a successor that may be tens of seconds away, with its row
                // spinning the whole time. A handful of pending sizes flushes on count instead.
                guard pending.count >= 4 || now - lastFlush >= .milliseconds(150) else { continue }
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
                kind: $0.kind,
                title: "\($0.kind.title): \($0.title)",
                sizeBytes: size(of: $0),
                isDestructive: $0.isDestructive
            )
        }
        guard entries.isEmpty == false else { return }
        pendingConfirmation = Confirmation(kind: .cleanup, entries: entries)
    }

    func confirmXcodeCleanup() async {
        // The selection and the scan it came from are read together: the deleter's allowlist is
        // derived from the scan, so a suspension point between the two reads could hand a set of
        // items to a deleter built for a different scan.
        let selection = selectedItems
        let snapshot = scan
        pendingConfirmation = nil
        cancelMeasuring()
        await work {
            let cleaner = Cleaner(
                runner: runner,
                deleter: scanner.makeDeleter(for: snapshot),
                home: cachePaths.home
            )
            let report = try await cleaner.run(selection) { [weak self] line in
                Task { @MainActor in self?.log(line) }
            }
            lastReport = report
            showsLastResult = report.freedBytes != nil
            section = .log
        }
        await rescan()
    }

    // MARK: Arcadia

    /// Measuring stops before `arc` is asked to unmount anything: a `readdir` inside a live FUSE
    /// mount is exactly what makes the volume report as busy, and the app must not be the process
    /// that blocks its own unmount and then offers `--force` for it.
    func unmountSelected(force: Bool = false) async {
        let mounts = selectedMounts.filter { $0.mount.isMounted }
        unmountRetryPath = nil
        cancelMeasuring()
        await work {
            var failures: [String] = []
            for info in mounts {
                do {
                    try await mountManager.unmount(info.mount.mount, force: force) { [weak self] line in
                        Task { @MainActor in self?.log(line) }
                    }
                } catch {
                    if force == false, unmountRetryPath == nil,
                       let mountError = error as? ArcMountError, case .commandFailed = mountError {
                        unmountRetryPath = info.mount.mount
                    }
                    failures.append("\(info.mount.name): \(error.localizedDescription)")
                }
            }
            guard failures.isEmpty else {
                throw MountBatchError(messages: failures)
            }
        }
        await rescan()
    }

    func retryUnmountWithForce() async {
        guard let path = unmountRetryPath else { return }
        unmountRetryPath = nil
        cancelMeasuring()
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
                kind: nil,
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
            var failures: [String] = []
            for info in mounts {
                do {
                    // The store size is whatever the streamed scan already measured, so the removal
                    // never re-walks gigabytes just to report the space it freed.
                    try await mountManager.remove(info.mount, knownStoreSize: size(of: info)) { [weak self] line in
                        Task { @MainActor in self?.log(line) }
                    }
                } catch {
                    failures.append("\(info.mount.name): \(error.localizedDescription)")
                }
            }
            guard failures.isEmpty else {
                throw MountBatchError(messages: failures)
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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A cleanup streams every `simctl` and `arc` line through here, so the buffer is capped and
    /// trimmed in blocks rather than per line. The complete log is on disk either way.
    private static let logLineLimit = 5000
    private static let logTrimSize = 1000

    func log(_ line: String) {
        logEntries.append(LogEntry(id: nextLogID, text: line))
        nextLogID += 1
        if logEntries.count > Self.logLineLimit {
            logEntries.removeFirst(Self.logTrimSize)
        }
        if logFile == nil {
            logFile = try? CleanupLogFile(directory: CleanupLogFile.defaultDirectory(home: cachePaths.home))
        }
        logFile?.appendLine(line)
    }

    /// The walks outlive the model otherwise: each one holds a thread of the cooperative pool, and
    /// some of them are inside FUSE mounts.
    isolated deinit {
        measureTask?.cancel()
    }
}
