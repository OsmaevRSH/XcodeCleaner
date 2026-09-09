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
        case .cleanup: "Очистить выбранное"
        case .deleteMounts: "Удалить маунты Arcadia"
        }
    }
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
            case .log: "Лог"
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
    var selectedItemIDs: Set<String> = []
    var simulatorMode: SimulatorMode = .deleteUnavailable
    var archiveMaxAgeDays = 30
    var selectedMountIDs: Set<String> = []
    var newMountName = ""
    var logLines: [String] = []
    var lastReport: CleanupReport?
    var errorMessage: String?
    var pendingConfirmation: Confirmation?
    var unmountRetryPath: String?

    private let runner: any CommandRunning
    private let cachePaths: CachePaths
    private let scanner: XcodeCleanerCore.Scanner
    private let mountManager: ArcMountManager
    private var logFile: CleanupLogFile?

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

    var selectedItems: [CleanupItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    var selectedMounts: [ArcMountInfo] {
        scan.mounts.filter { selectedMountIDs.contains($0.id) && $0.isMain == false }
    }

    var bytesToFree: Int64 {
        let fromItems = selectedItems.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        let fromMounts = selectedMounts.reduce(0) { $0 + ($1.storeSizeBytes ?? 0) }
        return fromItems + fromMounts
    }

    func isSelected(_ item: CleanupItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    func toggle(_ item: CleanupItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func setSelected(kind: CleanupKind, _ selected: Bool) {
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

    // MARK: Scan

    func rescan() async {
        guard isScanning == false else { return }
        isScanning = true
        defer { isScanning = false }
        scan = await scanner.scan()
        let validIDs = Set(items.map(\.id))
        selectedItemIDs.formIntersection(validIDs)
        selectedMountIDs.formIntersection(Set(scan.mounts.map(\.id)))
        for warning in scan.warnings {
            log("⚠︎ \(warning)")
        }
    }

    // MARK: Cleanup

    func requestCleanup() {
        let entries = selectedItems.map {
            ConfirmEntry(
                id: $0.id,
                title: "\($0.kind.title): \($0.title)",
                sizeBytes: $0.sizeBytes,
                isDestructive: $0.isDestructive
            )
        }
        guard entries.isEmpty == false else { return }
        pendingConfirmation = Confirmation(kind: .cleanup, entries: entries)
    }

    func confirmCleanup() async {
        let items = selectedItems
        pendingConfirmation = nil
        await work {
            let cleaner = Cleaner(runner: runner, deleter: scanner.makeDeleter(for: scan), home: cachePaths.home)
            let report = try await cleaner.run(items) { [weak self] line in
                Task { @MainActor in self?.log(line) }
            }
            lastReport = report
            section = .log
        }
        await rescan()
    }

    // MARK: Arcadia

    func mountNew() async {
        let name = newMountName
        await work {
            let path = try await mountManager.mountNew(name: name) { [weak self] line in
                Task { @MainActor in self?.log(line) }
            }
            log("Смонтировано: \(path.path)")
            newMountName = ""
        }
        await rescan()
    }

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

    func requestDeleteMounts() {
        let entries = selectedMounts.map {
            ConfirmEntry(
                id: $0.id,
                title: "Arcadia: \($0.mount.name)",
                sizeBytes: $0.storeSizeBytes,
                isDestructive: true
            )
        }
        guard entries.isEmpty == false else { return }
        pendingConfirmation = Confirmation(kind: .deleteMounts, entries: entries)
    }

    func confirmDeleteMounts() async {
        let mounts = selectedMounts
        pendingConfirmation = nil
        await work {
            for info in mounts {
                try await mountManager.forget(info.mount) { [weak self] line in
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
