# XcodeCleaner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS-приложение на SwiftUI, которое чистит кэши Xcode/симуляторов, старые Archives, неиспользуемые Xcode.app и toolchains, проектные кэши, и управляет маунтами Arcadia (mount / unmount / forget).

**Architecture:** SwiftPM-пакет из трёх таргетов: библиотека `XcodeCleanerCore` (модели, сканирование, безопасное удаление, обёртка над `Process`), executable `XcodeCleaner` (SwiftUI, `@Observable` модель, views) и тесты `XcodeCleanerCoreTests`. Все внешние команды (`xcrun simctl`, `arc`, `xcode-select`, `pgrep`) идут через протокол `CommandRunning`, в тестах подменяемый `FakeCommandRunner`. Удаление только через `SafeDeleter` с allowlist. `build.sh` собирает `.app` без Xcode-проекта.

**Tech Stack:** Swift 6.2, SwiftPM (tools 6.0), SwiftUI, Observation, XCTest, macOS 15+.

**Repo:** `~/Developer/XcodeCleaner` (git, ветка `main`). Все команды в плане запускаются из этого каталога.

**Spec:** `docs/superpowers/specs/2026-09-09-xcode-cleaner-design.md`.

---

## Файловая структура

```
Package.swift
build.sh
.gitignore
Assets/AppIcon.png                          # опционально, для .icns
Sources/XcodeCleanerCore/
  ByteFormatting.swift                      # человекочитаемые размеры
  CommandRunner.swift                       # CommandRunning, CommandResult, ExecutableLocator, ProcessCommandRunner
  DiskSpace.swift                           # свободно/занято/всего
  DirectorySizer.swift                      # размер каталога без прохода по симлинкам
  SafeDeleter.swift                         # allowlist, clearContents, trash
  CleanupModel.swift                        # CleanupKind, SimulatorMode, CleanupItem, CachePaths, CacheItemBuilder
  Simulators.swift                          # SimulatorInventory, парсинг simctl JSON, SimulatorScanner
  Archives.swift                            # ArchiveEntry, ArchiveScanner
  XcodeInstallations.swift                  # XcodeInstallation, ToolchainEntry, XcodeInstallationScanner
  ArcMounts.swift                           # ArcMount, ArcMountInfo, ArcMountManager
  ProjectCaches.swift                       # ProjectCacheScanner
  RunningAppsCheck.swift                    # pgrep Xcode/Simulator/xcodebuild/xctest
  CleanupLogFile.swift                      # запись лога в файл
  Scanner.swift                             # ScanResult, Scanner (композиция)
  Cleaner.swift                             # CleanupReport, Cleaner (порядок и выполнение)
Sources/XcodeCleaner/
  XcodeCleanerApp.swift                     # @main
  AppModel.swift                            # @MainActor @Observable
  Views/RootView.swift                      # NavigationSplitView, футер
  Views/DiskHeaderView.swift
  Views/XcodeSectionView.swift
  Views/ArcadiaSectionView.swift
  Views/LogView.swift
  Views/ConfirmSheet.swift
Tests/XcodeCleanerCoreTests/
  Support/FakeCommandRunner.swift
  Support/TemporaryDirectory.swift
  ByteFormattingTests.swift
  CommandRunnerTests.swift
  DiskSpaceTests.swift
  DirectorySizerTests.swift
  SafeDeleterTests.swift
  CleanupModelTests.swift
  SimulatorsTests.swift
  ArchivesTests.swift
  XcodeInstallationsTests.swift
  ArcMountsTests.swift
  ProjectCachesTests.swift
  RunningAppsCheckTests.swift
  CleanupLogFileTests.swift
  CleanerTests.swift
```

---

### Task 1: Каркас пакета и ByteFormatting

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/XcodeCleanerCore/ByteFormatting.swift`
- Create: `Sources/XcodeCleaner/XcodeCleanerApp.swift`
- Create: `Tests/XcodeCleanerCoreTests/ByteFormattingTests.swift`

- [ ] **Step 1: Создать Package.swift и .gitignore**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XcodeCleaner",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "XcodeCleanerCore"),
        .executableTarget(
            name: "XcodeCleaner",
            dependencies: ["XcodeCleanerCore"]
        ),
        .testTarget(
            name: "XcodeCleanerCoreTests",
            dependencies: ["XcodeCleanerCore"]
        ),
    ]
)
```

`.gitignore`:

```
.build/
.swiftpm/
*.app/
DerivedData/
.DS_Store
```

- [ ] **Step 2: Минимальное приложение, чтобы пакет собирался**

`Sources/XcodeCleaner/XcodeCleanerApp.swift`:

```swift
import SwiftUI

@main
struct XcodeCleanerApp: App {
    var body: some Scene {
        WindowGroup("XcodeCleaner") {
            Text("XcodeCleaner")
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}
```

- [ ] **Step 3: Падающий тест ByteFormatting**

`Tests/XcodeCleanerCoreTests/ByteFormattingTests.swift`:

```swift
import XCTest
@testable import XcodeCleanerCore

final class ByteFormattingTests: XCTestCase {
    func test_zeroBytes() {
        XCTAssertEqual(ByteFormatting.string(0), "0 B")
    }

    func test_kilobytesWithTwoDecimals() {
        XCTAssertEqual(ByteFormatting.string(1536), "1.50 KB")
    }

    func test_gigabytes() {
        XCTAssertEqual(ByteFormatting.string(5_261_334_937), "4.90 GB")
    }

    func test_negativeValueKeepsSign() {
        XCTAssertEqual(ByteFormatting.string(-1024), "-1.00 KB")
    }
}
```

- [ ] **Step 4: Запустить тесты, убедиться, что падают на компиляции**

Run: `swift test 2>&1 | tail -5`
Expected: ошибка `cannot find 'ByteFormatting' in scope`.

- [ ] **Step 5: Реализация**

`Sources/XcodeCleanerCore/ByteFormatting.swift`:

```swift
import Foundation

public enum ByteFormatting {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    public static func string(_ bytes: Int64) -> String {
        var value = Double(bytes.magnitude)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let sign = bytes < 0 ? "-" : ""
        if unitIndex == 0 {
            return "\(sign)\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%@%.2f %@", sign, value, units[unitIndex])
    }
}
```

- [ ] **Step 6: Прогнать тесты**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "Scaffold SwiftPM package with ByteFormatting"
```

---

### Task 2: CommandRunner и FakeCommandRunner

**Files:**
- Create: `Sources/XcodeCleanerCore/CommandRunner.swift`
- Create: `Tests/XcodeCleanerCoreTests/Support/FakeCommandRunner.swift`
- Create: `Tests/XcodeCleanerCoreTests/Support/LineCollector.swift`
- Create: `Tests/XcodeCleanerCoreTests/CommandRunnerTests.swift`

- [ ] **Step 1: Падающие тесты**

`Tests/XcodeCleanerCoreTests/CommandRunnerTests.swift`:

```swift
import XCTest
@testable import XcodeCleanerCore

final class CommandRunnerTests: XCTestCase {
    func test_echoReturnsStdoutAndZeroExit() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run("echo", ["hello"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertTrue(result.succeeded)
    }

    func test_nonZeroExitCodeIsReported() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run("sh", ["-c", "echo err 1>&2; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stderr, "err")
        XCTAssertFalse(result.succeeded)
    }

    func test_outputLinesAreStreamed() async throws {
        let runner = ProcessCommandRunner()
        let collector = LineCollector()
        _ = try await runner.run("sh", ["-c", "echo one; echo two"]) { line in
            collector.append(line)
        }
        XCTAssertEqual(collector.lines.sorted(), ["one", "two"])
    }

    func test_missingExecutableThrows() async {
        let runner = ProcessCommandRunner()
        do {
            _ = try await runner.run("definitely-not-a-binary-xyz", [])
            XCTFail("expected throw")
        } catch let error as CommandError {
            XCTAssertEqual(error.executable, "definitely-not-a-binary-xyz")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_locatorFindsBinaryInSearchDirectories() {
        let locator = ExecutableLocator(searchDirectories: ["/bin", "/usr/bin"])
        XCTAssertEqual(locator.resolve("ls"), "/bin/ls")
        XCTAssertNil(locator.resolve("no-such-binary-xyz"))
    }
}
```

`Tests/XcodeCleanerCoreTests/Support/LineCollector.swift` (потокобезопасный сборщик строк лога, нужен потому, что `@Sendable`-замыкание не может мутировать захваченный `var`):

```swift
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
```

`Tests/XcodeCleanerCoreTests/Support/FakeCommandRunner.swift`:

```swift
import Foundation
@testable import XcodeCleanerCore

final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let currentDirectory: String?

        var line: String { ([executable] + arguments).joined(separator: " ") }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var responses: [String: CommandResult] = [:]
    var defaultResult = CommandResult(exitCode: 0, stdout: "", stderr: "")

    var calls: [Call] { lock.withLock { recorded } }
    var callLines: [String] { calls.map(\.line) }

    func respond(to line: String, stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        responses[line] = CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL?,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, currentDirectory: currentDirectory?.path)
        lock.withLock { recorded.append(call) }
        let result = responses[call.line] ?? defaultResult
        if let onOutputLine {
            for line in result.stdout.split(separator: "\n") {
                onOutputLine(String(line))
            }
        }
        return result
    }
}
```

- [ ] **Step 2: Запустить тесты, убедиться, что падают**

Run: `swift test 2>&1 | tail -5`
Expected: ошибки компиляции `cannot find type 'CommandRunning'`.

- [ ] **Step 3: Реализация**

`Sources/XcodeCleanerCore/CommandRunner.swift`:

```swift
import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

public struct CommandError: Error, Equatable, Sendable {
    public let executable: String
    public let message: String

    public init(executable: String, message: String) {
        self.executable = executable
        self.message = message
    }
}

public protocol CommandRunning: Sendable {
    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL?,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments, currentDirectory: nil, onOutputLine: nil)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try await run(executable, arguments, currentDirectory: nil, onOutputLine: onOutputLine)
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL,
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments,
            currentDirectory: Optional(currentDirectory),
            onOutputLine: Optional(onOutputLine)
        )
    }
}

public struct ExecutableLocator: Sendable {
    public let searchDirectories: [String]

    public init(searchDirectories: [String]) {
        self.searchDirectories = searchDirectories
    }

    public static var standard: ExecutableLocator {
        let fromEnvironment = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let wellKnown = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let merged = (wellKnown + fromEnvironment).filter { seen.insert($0).inserted }
        return ExecutableLocator(searchDirectories: merged)
    }

    public func resolve(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

public final class ProcessCommandRunner: CommandRunning {
    private let locator: ExecutableLocator

    public init(locator: ExecutableLocator = .standard) {
        self.locator = locator
    }

    public func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL?,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        guard let path = locator.resolve(executable) else {
            throw CommandError(executable: executable, message: "Executable not found in search directories")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = locator.searchDirectories.joined(separator: ":")
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CommandError(executable: executable, message: error.localizedDescription)
        }

        async let stdoutText = Self.collect(stdoutPipe.fileHandleForReading, onOutputLine)
        async let stderrText = Self.collect(stderrPipe.fileHandleForReading, onOutputLine)
        let stdout = await stdoutText
        let stderr = await stderrText
        process.waitUntilExit()
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func collect(
        _ handle: FileHandle,
        _ onOutputLine: (@Sendable (String) -> Void)?
    ) async -> String {
        var lines: [String] = []
        do {
            for try await line in handle.bytes.lines {
                lines.append(line)
                onOutputLine?(line)
            }
        } catch {
            lines.append("[read error] \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add CommandRunning protocol, ProcessCommandRunner and test fake"
```

---

### Task 3: DiskSpace

**Files:**
- Create: `Sources/XcodeCleanerCore/DiskSpace.swift`
- Create: `Tests/XcodeCleanerCoreTests/DiskSpaceTests.swift`

- [ ] **Step 1: Падающий тест**

```swift
import XCTest
@testable import XcodeCleanerCore

final class DiskSpaceTests: XCTestCase {
    func test_usedIsTotalMinusAvailable() {
        let space = DiskSpace(total: 1000, available: 250)
        XCTAssertEqual(space.used, 750)
    }

    func test_currentHomeVolumeHasSaneNumbers() throws {
        let space = try DiskSpace.current()
        XCTAssertGreaterThan(space.total, 0)
        XCTAssertLessThanOrEqual(space.available, space.total)
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что падает на компиляции**

Run: `swift test --filter DiskSpaceTests 2>&1 | tail -5`

- [ ] **Step 3: Реализация**

`Sources/XcodeCleanerCore/DiskSpace.swift`:

```swift
import Foundation

public struct DiskSpace: Sendable, Equatable {
    public let total: Int64
    public let available: Int64

    public init(total: Int64, available: Int64) {
        self.total = total
        self.available = available
    }

    public var used: Int64 { total - available }

    public enum Failure: Error, Equatable {
        case unavailable(String)
    }

    public static func current(
        for url: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> DiskSpace {
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else {
            throw Failure.unavailable(url.path)
        }
        return DiskSpace(total: Int64(total), available: available)
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter DiskSpaceTests 2>&1 | tail -5`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add DiskSpace"
```

---

### Task 4: DirectorySizer и TemporaryDirectory helper

**Files:**
- Create: `Sources/XcodeCleanerCore/DirectorySizer.swift`
- Create: `Tests/XcodeCleanerCoreTests/Support/TemporaryDirectory.swift`
- Create: `Tests/XcodeCleanerCoreTests/DirectorySizerTests.swift`

- [ ] **Step 1: Helper для временных каталогов**

`Tests/XcodeCleanerCoreTests/Support/TemporaryDirectory.swift`:

```swift
import Foundation

struct TemporaryDirectory {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeCleanerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.resolvingSymlinksInPath()
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func makeFile(_ relativePath: String, bytes: Int) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: target)
        return target
    }

    func makeSymlink(_ relativePath: String, to destination: URL) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
        return target
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 2: Падающий тест**

`Tests/XcodeCleanerCoreTests/DirectorySizerTests.swift`:

```swift
import XCTest
@testable import XcodeCleanerCore

final class DirectorySizerTests: XCTestCase {
    func test_sumsRegularFilesRecursively() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try temp.makeFile("a.bin", bytes: 10_000)
        try temp.makeFile("nested/b.bin", bytes: 20_000)

        let size = DirectorySizer.size(of: temp.url)

        XCTAssertGreaterThanOrEqual(size, 30_000)
        XCTAssertLessThan(size, 30_000 + 2 * 4096)
    }

    func test_doesNotFollowSymlinks() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let outside = try TemporaryDirectory()
        defer { outside.remove() }
        let big = try outside.makeFile("big.bin", bytes: 500_000)
        try temp.makeFile("small.bin", bytes: 1_000)
        _ = try temp.makeSymlink("link.bin", to: big)

        let size = DirectorySizer.size(of: temp.url)

        XCTAssertLessThan(size, 100_000)
    }

    func test_missingPathIsZero() {
        let missing = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        XCTAssertEqual(DirectorySizer.size(of: missing), 0)
    }
}
```

- [ ] **Step 3: Запустить, убедиться, что падает**

Run: `swift test --filter DirectorySizerTests 2>&1 | tail -5`

- [ ] **Step 4: Реализация**

`Sources/XcodeCleanerCore/DirectorySizer.swift`:

```swift
import Foundation

public enum DirectorySizer {
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
    ]

    public static func size(of url: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        if isDirectory.boolValue == false {
            return fileSize(url)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += fileSize(child)
        }
        return total
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true
        else {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
}
```

- [ ] **Step 5: Прогнать тесты**

Run: `swift test --filter DirectorySizerTests 2>&1 | tail -5`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "Add DirectorySizer"
```

---

### Task 5: SafeDeleter

**Files:**
- Create: `Sources/XcodeCleanerCore/SafeDeleter.swift`
- Create: `Tests/XcodeCleanerCoreTests/SafeDeleterTests.swift`

- [ ] **Step 1: Падающие тесты**

```swift
import XCTest
@testable import XcodeCleanerCore

final class SafeDeleterTests: XCTestCase {
    func test_clearContentsRemovesChildrenButKeepsDirectory() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let cache = try temp.makeDirectory("DerivedData")
        try temp.makeFile("DerivedData/a.bin", bytes: 10)
        try temp.makeFile("DerivedData/sub/b.bin", bytes: 10)
        try temp.makeFile("DerivedData/.hidden", bytes: 10)
        let deleter = SafeDeleter(clearableDirectories: [cache], trashableParents: [])

        let failures = try deleter.clearContents(of: cache)

        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func test_clearContentsRejectsPathOutsideAllowlist() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let allowed = try temp.makeDirectory("allowed")
        let other = try temp.makeDirectory("other")
        try temp.makeFile("other/keep.bin", bytes: 10)
        let deleter = SafeDeleter(clearableDirectories: [allowed], trashableParents: [])

        XCTAssertThrowsError(try deleter.clearContents(of: other)) { error in
            XCTAssertEqual(error as? SafeDeleterError, .notAllowed(other.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("keep.bin").path))
    }

    func test_clearContentsRefusesSymlinkedDirectory() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let real = try temp.makeDirectory("real")
        try temp.makeFile("real/keep.bin", bytes: 10)
        let link = try temp.makeSymlink("link", to: real)
        let deleter = SafeDeleter(clearableDirectories: [link], trashableParents: [])

        XCTAssertThrowsError(try deleter.clearContents(of: link)) { error in
            XCTAssertEqual(error as? SafeDeleterError, .isSymlink(link.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("keep.bin").path))
    }

    func test_clearContentsRemovesSymlinkChildWithoutFollowing() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let cache = try temp.makeDirectory("cache")
        let outside = try temp.makeDirectory("outside")
        try temp.makeFile("outside/keep.bin", bytes: 10)
        _ = try temp.makeSymlink("cache/link", to: outside)
        let deleter = SafeDeleter(clearableDirectories: [cache], trashableParents: [])

        let failures = try deleter.clearContents(of: cache)

        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func test_trashRejectsItemOutsideTrashableParents() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let parent = try temp.makeDirectory("Archives")
        let stray = try temp.makeFile("stray.bin", bytes: 10)
        let deleter = SafeDeleter(clearableDirectories: [], trashableParents: [parent])

        XCTAssertThrowsError(try deleter.trash(stray)) { error in
            XCTAssertEqual(error as? SafeDeleterError, .notAllowed(stray.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    func test_trashMovesDirectChildOfTrashableParent() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let parent = try temp.makeDirectory("Archives")
        let item = try temp.makeFile("Archives/old.xcarchive", bytes: 10)
        let deleter = SafeDeleter(clearableDirectories: [], trashableParents: [parent])

        try deleter.trash(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что падает**

Run: `swift test --filter SafeDeleterTests 2>&1 | tail -5`

- [ ] **Step 3: Реализация**

`Sources/XcodeCleanerCore/SafeDeleter.swift`:

```swift
import Foundation

public struct DeletionFailure: Sendable, Equatable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public enum SafeDeleterError: Error, Equatable, Sendable {
    case notAllowed(String)
    case notADirectory(String)
    case isSymlink(String)
    case cannotInspect(String)
}

public struct SafeDeleter: Sendable {
    public let clearableDirectories: Set<String>
    public let trashableParents: Set<String>

    public init(clearableDirectories: [URL], trashableParents: [URL]) {
        self.clearableDirectories = Set(clearableDirectories.map(Self.normalize))
        self.trashableParents = Set(trashableParents.map(Self.normalize))
    }

    public func clearContents(
        of directory: URL,
        fileManager: FileManager = .default
    ) throws -> [DeletionFailure] {
        let path = Self.normalize(directory)
        guard clearableDirectories.contains(path) else {
            throw SafeDeleterError.notAllowed(directory.path)
        }
        let attributes = try Self.attributes(atPath: directory.path, fileManager: fileManager)
        if attributes.type == .typeSymbolicLink {
            throw SafeDeleterError.isSymlink(directory.path)
        }
        guard attributes.type == .typeDirectory else {
            throw SafeDeleterError.notADirectory(directory.path)
        }

        var failures: [DeletionFailure] = []
        let children = try fileManager.contentsOfDirectory(atPath: directory.path)
        for name in children {
            let child = directory.appendingPathComponent(name)
            do {
                let childAttributes = try Self.attributes(atPath: child.path, fileManager: fileManager)
                if childAttributes.type != .typeSymbolicLink,
                   childAttributes.device != attributes.device {
                    failures.append(DeletionFailure(path: child.path, reason: "nested volume, skipped"))
                    continue
                }
                try fileManager.removeItem(at: child)
            } catch {
                failures.append(DeletionFailure(path: child.path, reason: error.localizedDescription))
            }
        }
        return failures
    }

    public func trash(_ url: URL, fileManager: FileManager = .default) throws {
        let parent = Self.normalize(url.deletingLastPathComponent())
        guard trashableParents.contains(parent) else {
            throw SafeDeleterError.notAllowed(url.path)
        }
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    private struct ItemAttributes {
        let type: FileAttributeType
        let device: Int
    }

    private static func attributes(atPath path: String, fileManager: FileManager) throws -> ItemAttributes {
        let raw: [FileAttributeKey: Any]
        do {
            raw = try fileManager.attributesOfItem(atPath: path)
        } catch {
            throw SafeDeleterError.cannotInspect(path)
        }
        let type = (raw[.type] as? FileAttributeType) ?? .typeUnknown
        let device = (raw[.systemNumber] as? Int) ?? -1
        return ItemAttributes(type: type, device: device)
    }

    private static func normalize(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter SafeDeleterTests 2>&1 | tail -5`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add SafeDeleter with allowlist and trash support"
```

---

### Task 6: CleanupModel (kinds, items, CachePaths, CacheItemBuilder)

**Files:**
- Create: `Sources/XcodeCleanerCore/CleanupModel.swift`
- Create: `Tests/XcodeCleanerCoreTests/CleanupModelTests.swift`

- [ ] **Step 1: Падающие тесты**

```swift
import XCTest
@testable import XcodeCleanerCore

final class CleanupModelTests: XCTestCase {
    func test_cachePathsAreRootedInHome() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let paths = CachePaths(home: home)

        XCTAssertEqual(paths.xcodeCaches.map(\.path), [
            "/Users/tester/Library/Developer/Xcode/DerivedData",
            "/Users/tester/Library/Developer/Xcode/DocumentationCache",
            "/Users/tester/Library/Developer/Xcode/UserData/Previews",
            "/Users/tester/Library/Caches/com.apple.dt.Xcode",
        ])
        XCTAssertEqual(paths.deviceSupport.count, 4)
        XCTAssertEqual(paths.archivesDirectory.path, "/Users/tester/Library/Developer/Xcode/Archives")
        XCTAssertEqual(paths.toolchainsDirectory.path, "/Users/tester/Library/Developer/Toolchains")
        XCTAssertEqual(paths.globalProjectCaches.map(\.path), ["/Users/tester/.cache/tuist"])
        XCTAssertEqual(paths.allClearable.count, 4 + 4 + 4 + 1)
    }

    func test_cacheItemBuilderSkipsMissingDirectories() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let existing = try temp.makeDirectory("DerivedData")
        try temp.makeFile("DerivedData/x.bin", bytes: 4096)
        let missing = temp.url.appendingPathComponent("Missing")

        let items = CacheItemBuilder.items(kind: .xcodeCaches, directories: [existing, missing])

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, existing.path)
        XCTAssertEqual(items[0].kind, .xcodeCaches)
        XCTAssertEqual(items[0].action, .clearContents(existing))
        XCTAssertFalse(items[0].isDestructive)
        XCTAssertGreaterThanOrEqual(items[0].sizeBytes ?? 0, 4096)
    }

    func test_simulatorModeDestructiveness() {
        XCTAssertFalse(SimulatorMode.deleteUnavailable.isDestructive)
        XCTAssertTrue(SimulatorMode.eraseAll.isDestructive)
        XCTAssertTrue(SimulatorMode.deleteAll.isDestructive)
        XCTAssertTrue(SimulatorMode.deleteAllAndRuntimes.isDestructive)
    }

    func test_kindsHaveExecutionOrder() {
        XCTAssertEqual(CleanupKind.executionOrder, [
            .xcodeCaches, .deviceSupport, .simulatorCaches, .simulators,
            .archives, .xcodeApps, .toolchains, .projectCaches,
        ])
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что падает**

Run: `swift test --filter CleanupModelTests 2>&1 | tail -5`

- [ ] **Step 3: Реализация**

`Sources/XcodeCleanerCore/CleanupModel.swift`:

```swift
import Foundation

public enum CleanupKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case xcodeCaches
    case deviceSupport
    case simulatorCaches
    case simulators
    case archives
    case xcodeApps
    case toolchains
    case projectCaches

    public var id: String { rawValue }

    public static let executionOrder: [CleanupKind] = [
        .xcodeCaches, .deviceSupport, .simulatorCaches, .simulators,
        .archives, .xcodeApps, .toolchains, .projectCaches,
    ]

    public var title: String {
        switch self {
        case .xcodeCaches: "Кэши Xcode"
        case .deviceSupport: "DeviceSupport"
        case .simulatorCaches: "CoreSimulator и SwiftPM"
        case .simulators: "Симуляторы"
        case .archives: "Archives"
        case .xcodeApps: "Старые Xcode"
        case .toolchains: "Toolchains"
        case .projectCaches: "Проектные кэши"
        }
    }
}

public enum SimulatorMode: String, CaseIterable, Sendable, Hashable, Identifiable {
    case deleteUnavailable
    case eraseAll
    case deleteAll
    case deleteAllAndRuntimes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .deleteUnavailable: "Удалить только недоступные"
        case .eraseAll: "Стереть данные всех симуляторов"
        case .deleteAll: "Удалить все симуляторы"
        case .deleteAllAndRuntimes: "Удалить все симуляторы и runtimes"
        }
    }

    public var isDestructive: Bool { self != .deleteUnavailable }
}

public struct CleanupItem: Identifiable, Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case clearContents(URL)
        case trash(URL)
        case simulators(SimulatorMode)
    }

    public let id: String
    public let kind: CleanupKind
    public let title: String
    public let subtitle: String
    public let action: Action
    public let sizeBytes: Int64?
    public let isDestructive: Bool

    public init(
        id: String,
        kind: CleanupKind,
        title: String,
        subtitle: String,
        action: Action,
        sizeBytes: Int64?,
        isDestructive: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.sizeBytes = sizeBytes
        self.isDestructive = isDestructive
    }
}

public struct CachePaths: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    public static let projectCacheSubpaths = [
        "mobile/saft/ios/Tuist/.build",
        "mobile/saft/ios/Derived",
        "mobile/saft/ios/DerivedData",
    ]

    private func library(_ path: String) -> URL {
        home.appendingPathComponent("Library").appendingPathComponent(path)
    }

    public var xcodeCaches: [URL] {
        [
            library("Developer/Xcode/DerivedData"),
            library("Developer/Xcode/DocumentationCache"),
            library("Developer/Xcode/UserData/Previews"),
            library("Caches/com.apple.dt.Xcode"),
        ]
    }

    public var deviceSupport: [URL] {
        ["iOS", "watchOS", "tvOS", "visionOS"].map {
            library("Developer/Xcode/\($0) DeviceSupport")
        }
    }

    public var simulatorCaches: [URL] {
        [
            library("Developer/CoreSimulator/Caches"),
            library("Caches/com.apple.CoreSimulator"),
            library("Caches/org.swift.swiftpm"),
            library("Logs/CoreSimulator"),
        ]
    }

    public var globalProjectCaches: [URL] {
        [home.appendingPathComponent(".cache/tuist")]
    }

    public var archivesDirectory: URL { library("Developer/Xcode/Archives") }
    public var toolchainsDirectory: URL { library("Developer/Toolchains") }
    public var applicationsDirectory: URL { URL(fileURLWithPath: "/Applications") }
    public var arcStoresDirectory: URL { home.appendingPathComponent(".arc/stores") }
    public var mainArcadiaMount: URL { home.appendingPathComponent("arcadia") }

    public var allClearable: [URL] {
        xcodeCaches + deviceSupport + simulatorCaches + globalProjectCaches
    }

    public func projectCacheDirectories(inMount mount: URL) -> [URL] {
        Self.projectCacheSubpaths.map { mount.appendingPathComponent($0) }
    }
}

public enum CacheItemBuilder {
    public static func items(
        kind: CleanupKind,
        directories: [URL],
        fileManager: FileManager = .default
    ) -> [CleanupItem] {
        directories.compactMap { directory in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return nil
            }
            return CleanupItem(
                id: directory.path,
                kind: kind,
                title: directory.lastPathComponent,
                subtitle: directory.path,
                action: .clearContents(directory),
                sizeBytes: DirectorySizer.size(of: directory, fileManager: fileManager),
                isDestructive: false
            )
        }
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter CleanupModelTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add cleanup model: kinds, items, cache paths"
```

---

### Task 7: Simulators (парсинг simctl JSON, оценка размера)

**Files:**
- Create: `Sources/XcodeCleanerCore/Simulators.swift`
- Create: `Tests/XcodeCleanerCoreTests/SimulatorsTests.swift`

- [ ] **Step 1: Падающие тесты**

```swift
import XCTest
@testable import XcodeCleanerCore

final class SimulatorsTests: XCTestCase {
    private let devicesJSON = """
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
          {
            "udid" : "AAAA",
            "name" : "iPhone 17 Pro",
            "isAvailable" : true,
            "state" : "Booted",
            "dataPathSize" : 4000
          },
          {
            "udid" : "BBBB",
            "name" : "iPhone 15",
            "isAvailable" : false,
            "state" : "Shutdown",
            "dataPathSize" : 500
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-26-2" : [ ]
      }
    }
    """.data(using: .utf8)!

    private let runtimesJSON = """
    {
      "R1" : {
        "identifier" : "R1",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
        "version" : "26.2",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "sizeBytes" : 8000,
        "deletable" : true
      },
      "R2" : {
        "identifier" : "R2",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-17-5",
        "version" : "17.5",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "sizeBytes" : 7000,
        "deletable" : true
      }
    }
    """.data(using: .utf8)!

    func test_parsesDevicesAndRuntimes() throws {
        let inventory = try SimulatorInventory.parse(devicesJSON: devicesJSON, runtimesJSON: runtimesJSON)

        XCTAssertEqual(inventory.devices.map(\.udid).sorted(), ["AAAA", "BBBB"])
        XCTAssertEqual(inventory.unavailableDevices.map(\.udid), ["BBBB"])
        XCTAssertEqual(inventory.runtimes.map(\.version).sorted(), ["17.5", "26.2"])
        XCTAssertEqual(inventory.devicesDataSize, 4500)
        XCTAssertEqual(inventory.runtimesSize, 15000)
    }

    func test_estimatedFreedBytesPerMode() throws {
        let inventory = try SimulatorInventory.parse(devicesJSON: devicesJSON, runtimesJSON: runtimesJSON)

        XCTAssertEqual(inventory.estimatedFreedBytes(for: .deleteUnavailable), 500)
        XCTAssertEqual(inventory.estimatedFreedBytes(for: .eraseAll), 4500)
        XCTAssertEqual(inventory.estimatedFreedBytes(for: .deleteAll), 4500)
        XCTAssertEqual(inventory.estimatedFreedBytes(for: .deleteAllAndRuntimes), 19500)
    }

    func test_scannerCallsSimctl() async throws {
        let runner = FakeCommandRunner()
        runner.respond(to: "xcrun simctl list devices -j", stdout: String(data: devicesJSON, encoding: .utf8)!)
        runner.respond(to: "xcrun simctl runtime list -j", stdout: String(data: runtimesJSON, encoding: .utf8)!)
        let scanner = SimulatorScanner(runner: runner)

        let inventory = try await scanner.inventory()

        XCTAssertEqual(inventory.devices.count, 2)
        XCTAssertEqual(runner.callLines, ["xcrun simctl list devices -j", "xcrun simctl runtime list -j"])
    }

    func test_makeItemUsesModeTitleAndEstimate() throws {
        let inventory = try SimulatorInventory.parse(devicesJSON: devicesJSON, runtimesJSON: runtimesJSON)

        let item = inventory.makeItem(mode: .deleteAll)

        XCTAssertEqual(item.id, "simulators")
        XCTAssertEqual(item.kind, .simulators)
        XCTAssertEqual(item.action, .simulators(.deleteAll))
        XCTAssertEqual(item.sizeBytes, 4500)
        XCTAssertTrue(item.isDestructive)
        XCTAssertEqual(item.subtitle, "2 устройств, 1 недоступно, 2 runtimes")
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что падает**

Run: `swift test --filter SimulatorsTests 2>&1 | tail -5`

- [ ] **Step 3: Реализация**

`Sources/XcodeCleanerCore/Simulators.swift`:

```swift
import Foundation

public struct SimulatorDevice: Sendable, Equatable, Decodable {
    public let udid: String
    public let name: String
    public let isAvailable: Bool
    public let state: String
    public let dataPathSize: Int64?
}

public struct SimulatorRuntime: Sendable, Equatable, Decodable {
    public let identifier: String
    public let runtimeIdentifier: String
    public let version: String
    public let platformIdentifier: String
    public let sizeBytes: Int64
    public let deletable: Bool
}

public struct SimulatorInventory: Sendable, Equatable {
    public let devices: [SimulatorDevice]
    public let runtimes: [SimulatorRuntime]

    public init(devices: [SimulatorDevice], runtimes: [SimulatorRuntime]) {
        self.devices = devices
        self.runtimes = runtimes
    }

    public var availableDevices: [SimulatorDevice] { devices.filter(\.isAvailable) }
    public var unavailableDevices: [SimulatorDevice] { devices.filter { $0.isAvailable == false } }
    public var devicesDataSize: Int64 { devices.reduce(0) { $0 + ($1.dataPathSize ?? 0) } }
    public var runtimesSize: Int64 { runtimes.reduce(0) { $0 + $1.sizeBytes } }

    public func estimatedFreedBytes(for mode: SimulatorMode) -> Int64 {
        switch mode {
        case .deleteUnavailable:
            unavailableDevices.reduce(0) { $0 + ($1.dataPathSize ?? 0) }
        case .eraseAll, .deleteAll:
            devicesDataSize
        case .deleteAllAndRuntimes:
            devicesDataSize + runtimesSize
        }
    }

    public func makeItem(mode: SimulatorMode) -> CleanupItem {
        CleanupItem(
            id: "simulators",
            kind: .simulators,
            title: mode.title,
            subtitle: "\(devices.count) устройств, \(unavailableDevices.count) недоступно, \(runtimes.count) runtimes",
            action: .simulators(mode),
            sizeBytes: estimatedFreedBytes(for: mode),
            isDestructive: mode.isDestructive
        )
    }

    private struct DevicesPayload: Decodable {
        let devices: [String: [SimulatorDevice]]
    }

    public static func parse(devicesJSON: Data, runtimesJSON: Data) throws -> SimulatorInventory {
        let decoder = JSONDecoder()
        let devicesPayload = try decoder.decode(DevicesPayload.self, from: devicesJSON)
        let runtimesPayload = try decoder.decode([String: SimulatorRuntime].self, from: runtimesJSON)
        return SimulatorInventory(
            devices: devicesPayload.devices.values.flatMap { $0 },
            runtimes: Array(runtimesPayload.values)
        )
    }
}

public struct SimulatorScanner: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func inventory() async throws -> SimulatorInventory {
        let devices = try await runner.run("xcrun", ["simctl", "list", "devices", "-j"])
        let runtimes = try await runner.run("xcrun", ["simctl", "runtime", "list", "-j"])
        guard devices.succeeded, runtimes.succeeded else {
            throw CommandError(executable: "xcrun", message: devices.stderr + runtimes.stderr)
        }
        return try SimulatorInventory.parse(
            devicesJSON: Data(devices.stdout.utf8),
            runtimesJSON: Data(runtimes.stdout.utf8)
        )
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter SimulatorsTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add simulator inventory parsing and scanner"
```

---

### Task 8: Archives

**Files:**
- Create: `Sources/XcodeCleanerCore/Archives.swift`
- Create: `Tests/XcodeCleanerCoreTests/ArchivesTests.swift`

- [ ] **Step 1: Падающие тесты**

```swift
import XCTest
@testable import XcodeCleanerCore

final class ArchivesTests: XCTestCase {
    private func makeArchive(_ temp: TemporaryDirectory, _ relative: String, daysAgo: Int) throws -> URL {
        let url = try temp.makeDirectory(relative)
        try temp.makeFile("\(relative)/Info.plist", bytes: 100)
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
        return url
    }

    func test_findsArchivesTwoLevelsDeep() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let old = try makeArchive(temp, "2026-01-01/App 01.01.26.xcarchive", daysAgo: 100)
        let fresh = try makeArchive(temp, "2026-09-01/App 01.09.26.xcarchive", daysAgo: 3)
        try temp.makeDirectory("2026-09-01/NotAnArchive")

        let archives = ArchiveScanner.archives(in: temp.url)

        XCTAssertEqual(Set(archives.map(\.url.path)), [old.path, fresh.path])
        XCTAssertTrue(archives.allSatisfy { $0.sizeBytes >= 100 })
    }

    func test_filtersByAge() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let old = try makeArchive(temp, "2026-01-01/Old.xcarchive", daysAgo: 100)
        _ = try makeArchive(temp, "2026-09-01/Fresh.xcarchive", daysAgo: 3)
        let archives = ArchiveScanner.archives(in: temp.url)

        let stale = ArchiveScanner.olderThan(days: 30, archives)

        XCTAssertEqual(stale.map(\.url.path), [old.path])
    }

    func test_makeItemIsDestructiveTrash() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let old = try makeArchive(temp, "2026-01-01/Old.xcarchive", daysAgo: 100)
        let entry = ArchiveScanner.archives(in: temp.url)[0]

        let item = entry.makeItem()

        XCTAssertEqual(item.kind, .archives)
        XCTAssertEqual(item.action, .trash(old))
        XCTAssertTrue(item.isDestructive)
        XCTAssertEqual(item.title, "Old.xcarchive")
    }

    func test_missingDirectoryYieldsEmpty() {
        XCTAssertEqual(ArchiveScanner.archives(in: URL(fileURLWithPath: "/nonexistent/\(UUID())")), [])
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что падает**

Run: `swift test --filter ArchivesTests 2>&1 | tail -5`

- [ ] **Step 3: Реализация**

`Sources/XcodeCleanerCore/Archives.swift`:

```swift
import Foundation

public struct ArchiveEntry: Sendable, Equatable, Identifiable {
    public let url: URL
    public let createdAt: Date
    public let sizeBytes: Int64

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public func makeItem() -> CleanupItem {
        CleanupItem(
            id: url.path,
            kind: .archives,
            title: name,
            subtitle: url.deletingLastPathComponent().lastPathComponent,
            action: .trash(url),
            sizeBytes: sizeBytes,
            isDestructive: true
        )
    }
}

public enum ArchiveScanner {
    public static func archives(in directory: URL, fileManager: FileManager = .default) -> [ArchiveEntry] {
        guard let dayFolders = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [ArchiveEntry] = []
        for folder in dayFolders {
            guard let children = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children where child.pathExtension == "xcarchive" {
                let created = (try? child.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                result.append(ArchiveEntry(
                    url: child,
                    createdAt: created,
                    sizeBytes: DirectorySizer.size(of: child, fileManager: fileManager)
                ))
            }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    public static func olderThan(days: Int, now: Date = Date(), _ archives: [ArchiveEntry]) -> [ArchiveEntry] {
        let threshold = now.addingTimeInterval(-Double(days) * 86_400)
        return archives.filter { $0.createdAt < threshold }
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter ArchivesTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add archive scanner with age filter"
```

---

### Task 9: XcodeInstallations и Toolchains

**Files:**
- Create: `Sources/XcodeCleanerCore/XcodeInstallations.swift`
- Create: `Tests/XcodeCleanerCoreTests/XcodeInstallationsTests.swift`

- [ ] **Step 1: Падающие тесты**

```swift
import XCTest
@testable import XcodeCleanerCore

final class XcodeInstallationsTests: XCTestCase {
    func test_marksActiveXcodeFromDeveloperDir() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let active = try temp.makeDirectory("Xcode-26.2.0.app/Contents/Developer")
        let old = try temp.makeDirectory("Xcode-16.4.app/Contents/Developer")
        try temp.makeDirectory("Xcodes.app")
        try temp.makeDirectory("Safari.app")

        let installations = XcodeInstallationScanner.installations(
            in: temp.url,
            activeDeveloperDir: active.path
        )

        XCTAssertEqual(installations.map(\.name).sorted(), ["Xcode-16.4.app", "Xcode-26.2.0.app"])
        XCTAssertEqual(installations.first { $0.name == "Xcode-26.2.0.app" }?.isActive, true)
        XCTAssertEqual(installations.first { $0.name == "Xcode-16.4.app" }?.isActive, false)
        XCTAssertEqual(old.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Xcode-16.4.app")
    }

    func test_toolchainsProtectSwiftLatestAndItsTarget() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let latest = try temp.makeDirectory("swift-6.3.3-RELEASE.xctoolchain")
        try temp.makeDirectory("swift-5.9-RELEASE.xctoolchain")
        _ = try temp.makeSymlink("swift-latest.xctoolchain", to: latest)

        let toolchains = XcodeInstallationScanner.toolchains(in: temp.url)

        let byName = Dictionary(uniqueKeysWithValues: toolchains.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["swift-6.3.3-RELEASE.xctoolchain", "swift-5.9-RELEASE.xctoolchain", "swift-latest.xctoolchain"])
        XCTAssertEqual(byName["swift-latest.xctoolchain"]?.isProtected, true)
        XCTAssertEqual(byName["swift-6.3.3-RELEASE.xctoolchain"]?.isProtected, true)
        XCTAssertEqual(byName["swift-5.9-RELEASE.xctoolchain"]?.isProtected, false)
    }

    func test_activeDeveloperDirUsesXcodeSelect() async throws {
        let runner = FakeCommandRunner()
        runner.respond(to: "xcode-select -p", stdout: "/Applications/Xcode-26.2.0.app/Contents/Developer\n")

        let dir = try await XcodeInstallationScanner.activeDeveloperDir(runner: runner)

        XCTAssertEqual(dir, "/Applications/Xcode-26.2.0.app/Contents/Developer")
    }

    func test_itemsAreTrashAndDestructive() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let old = try temp.makeDirectory("Xcode-16.4.app/Contents/Developer")
        let installation = XcodeInstallationScanner.installations(in: temp.url, activeDeveloperDir: "/none")[0]
        let toolchainDir = try temp.makeDirectory("swift-5.9-RELEASE.xctoolchain")
        let toolchain = XcodeInstallationScanner.toolchains(in: temp.url)[0]

        XCTAssertEqual(installation.makeItem().action, .trash(old.deletingLastPathComponent().deletingLastPathComponent()))
        XCTAssertEqual(installation.makeItem().kind, .xcodeApps)
        XCTAssertTrue(installation.makeItem().isDestructive)
        XCTAssertEqual(toolchain.makeItem().action, .trash(toolchainDir))
        XCTAssertEqual(toolchain.makeItem().kind, .toolchains)
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что падает**

Run: `swift test --filter XcodeInstallationsTests 2>&1 | tail -5`

- [ ] **Step 3: Реализация**

`Sources/XcodeCleanerCore/XcodeInstallations.swift`:

```swift
import Foundation

public struct XcodeInstallation: Sendable, Equatable, Identifiable {
    public let url: URL
    public let isActive: Bool
    public let sizeBytes: Int64

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public func makeItem() -> CleanupItem {
        CleanupItem(
            id: url.path,
            kind: .xcodeApps,
            title: name,
            subtitle: url.path,
            action: .trash(url),
            sizeBytes: sizeBytes,
            isDestructive: true
        )
    }
}

public struct ToolchainEntry: Sendable, Equatable, Identifiable {
    public let url: URL
    public let isProtected: Bool
    public let sizeBytes: Int64

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public func makeItem() -> CleanupItem {
        CleanupItem(
            id: url.path,
            kind: .toolchains,
            title: name,
            subtitle: url.path,
            action: .trash(url),
            sizeBytes: sizeBytes,
            isDestructive: true
        )
    }
}

public enum XcodeInstallationScanner {
    public static func activeDeveloperDir(runner: any CommandRunning) async throws -> String {
        let result = try await runner.run("xcode-select", ["-p"])
        guard result.succeeded else {
            throw CommandError(executable: "xcode-select", message: result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func installations(
        in applications: URL,
        activeDeveloperDir: String,
        fileManager: FileManager = .default
    ) -> [XcodeInstallation] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let activePath = URL(fileURLWithPath: activeDeveloperDir).standardizedFileURL.path
        return children
            .filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
            .filter { $0.lastPathComponent != "Xcodes.app" }
            .map { url in
                let developer = url.appendingPathComponent("Contents/Developer").standardizedFileURL.path
                return XcodeInstallation(
                    url: url,
                    isActive: developer == activePath,
                    sizeBytes: DirectorySizer.size(of: url, fileManager: fileManager)
                )
            }
            .sorted { $0.name < $1.name }
    }

    public static func toolchains(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [ToolchainEntry] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let toolchainURLs = children.filter { $0.pathExtension == "xctoolchain" }
        let latestLink = toolchainURLs.first { $0.lastPathComponent == "swift-latest.xctoolchain" }
        let latestTarget = latestLink.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        return toolchainURLs.map { url in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            let isLatestLink = url.lastPathComponent == "swift-latest.xctoolchain"
            let isLatestTarget = latestTarget == resolved
            return ToolchainEntry(
                url: url,
                isProtected: isLatestLink || isLatestTarget,
                sizeBytes: isLatestLink ? 0 : DirectorySizer.size(of: url, fileManager: fileManager)
            )
        }
        .sorted { $0.name < $1.name }
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter XcodeInstallationsTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add Xcode installation and toolchain scanner"
```

---

### Task 10: ArcMounts (парсинг, менеджер mount/unmount/forget)

**Files:**
- Create: `Sources/XcodeCleanerCore/ArcMounts.swift`
- Create: `Tests/XcodeCleanerCoreTests/ArcMountsTests.swift`

- [ ] **Step 1: Падающие тесты**

```swift
import XCTest
@testable import XcodeCleanerCore

final class ArcMountsTests: XCTestCase {
    private let listJSON = """
    [
      {"status":"mounted","mount":"/Users/tester/arcadia","store":"/Users/tester/store","object-store":"/Users/tester/store/.arc/objects"},
      {"status":"unmounted","mount":"/Users/tester/arcadia_SAFTIOS-1","store":"/Users/tester/.arc/stores/_Users_tester_arcadia_SAFTIOS-1","object-store":"/Users/tester/store/.arc/objects"},
      {"status":"mounted","mount":"/Users/tester/arcadia_SAFTIOS-2","store":"/Users/tester/.arc/stores/_Users_tester_arcadia_SAFTIOS-2","object-store":"/Users/tester/.arc/stores/_Users_tester_arcadia_SAFTIOS-2/.arc/objects"}
    ]
    """

    private func makeManager(_ runner: FakeCommandRunner, home: URL) -> ArcMountManager {
        runner.respond(to: "arc mount --list --json", stdout: listJSON)
        return ArcMountManager(runner: runner, home: home)
    }

    func test_parsesList() throws {
        let mounts = try ArcMount.parse(Data(listJSON.utf8))

        XCTAssertEqual(mounts.count, 3)
        XCTAssertEqual(mounts[0].status, .mounted)
        XCTAssertEqual(mounts[1].status, .unmounted)
        XCTAssertEqual(mounts[1].objectStore, "/Users/tester/store/.arc/objects")
        XCTAssertEqual(mounts[1].name, "arcadia_SAFTIOS-1")
    }

    func test_listMarksMainAndSharedObjectStore() async throws {
        let runner = FakeCommandRunner()
        let manager = makeManager(runner, home: URL(fileURLWithPath: "/Users/tester"))

        let infos = try await manager.list()

        XCTAssertEqual(infos.map(\.mount.mount), [
            "/Users/tester/arcadia",
            "/Users/tester/arcadia_SAFTIOS-1",
            "/Users/tester/arcadia_SAFTIOS-2",
        ])
        XCTAssertTrue(infos[0].isMain)
        XCTAssertNil(infos[0].storeSizeBytes)
        XCTAssertTrue(infos[1].sharesMainObjectStore)
        XCTAssertFalse(infos[2].sharesMainObjectStore)
        XCTAssertEqual(runner.calls[0].currentDirectory, "/Users/tester")
    }

    func test_mountPathValidation() throws {
        let manager = ArcMountManager(runner: FakeCommandRunner(), home: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertEqual(try manager.mountPath(forName: "SAFTIOS-1").path, "/Users/tester/arcadia_SAFTIOS-1")
        XCTAssertThrowsError(try manager.mountPath(forName: ""))
        XCTAssertThrowsError(try manager.mountPath(forName: "a/b"))
        XCTAssertThrowsError(try manager.mountPath(forName: "a b"))
        XCTAssertThrowsError(try manager.mountPath(forName: ".."))
    }

    func test_mountNewRunsArcMountWithMainObjectStore() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let runner = FakeCommandRunner()
        let mainMount = temp.url.appendingPathComponent("arcadia").path
        runner.respond(
            to: "arc mount --list --json",
            stdout: """
            [{"status":"mounted","mount":"\(mainMount)","store":"/store","object-store":"/store/.arc/objects"}]
            """
        )
        let manager = ArcMountManager(runner: runner, home: temp.url)

        let path = try await manager.mountNew(name: "SAFTIOS-9") { _ in }

        XCTAssertEqual(path.path, temp.url.appendingPathComponent("arcadia_SAFTIOS-9").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(runner.callLines.last, "arc mount -m \(path.path) --object-store /store/.arc/objects --override-object-store")
    }

    func test_mountNewRefusesNonEmptyDirectory() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try temp.makeFile("arcadia_busy/file", bytes: 1)
        let runner = FakeCommandRunner()
        let manager = makeManager(runner, home: temp.url)

        do {
            _ = try await manager.mountNew(name: "busy") { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .directoryNotEmpty(temp.url.appendingPathComponent("arcadia_busy").path))
        }
        XCTAssertFalse(runner.callLines.contains { $0.hasPrefix("arc mount -m") })
    }

    func test_unmountWithAndWithoutForce() async throws {
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        try await manager.unmount("/Users/tester/arcadia_SAFTIOS-2", force: false) { _ in }
        try await manager.unmount("/Users/tester/arcadia_SAFTIOS-2", force: true) { _ in }

        XCTAssertEqual(runner.callLines, [
            "arc unmount /Users/tester/arcadia_SAFTIOS-2",
            "arc unmount --force /Users/tester/arcadia_SAFTIOS-2",
        ])
    }

    func test_unmountFailurePropagatesStderr() async {
        let runner = FakeCommandRunner()
        runner.respond(to: "arc unmount /Users/tester/arcadia_SAFTIOS-2", stderr: "busy", exitCode: 1)
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))

        do {
            try await manager.unmount("/Users/tester/arcadia_SAFTIOS-2", force: false) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .commandFailed("arc unmount", "busy"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_forgetUnmountsIfMountedThenForgetsAndRemovesEmptyDir() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-2")
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .mounted, mount: mountDir.path, store: "/s", objectStore: "/o")

        try await manager.forget(mount) { _ in }

        XCTAssertEqual(runner.callLines, [
            "arc unmount \(mountDir.path)",
            "arc unmount --forget \(mountDir.path)",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountDir.path))
    }

    func test_forgetKeepsNonEmptyDirectory() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mountDir = try temp.makeDirectory("arcadia_SAFTIOS-1")
        try temp.makeFile("arcadia_SAFTIOS-1/leftover", bytes: 1)
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: temp.url)
        let mount = ArcMount(status: .unmounted, mount: mountDir.path, store: "/s", objectStore: "/o")
        let logged = LineCollector()

        try await manager.forget(mount) { logged.append($0) }

        XCTAssertEqual(runner.callLines, ["arc unmount --forget \(mountDir.path)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountDir.path))
        XCTAssertTrue(logged.contains("не пуста"))
    }

    func test_forgetRefusesMainMount() async {
        let runner = FakeCommandRunner()
        let manager = ArcMountManager(runner: runner, home: URL(fileURLWithPath: "/Users/tester"))
        let main = ArcMount(status: .mounted, mount: "/Users/tester/arcadia", store: "/s", objectStore: "/o")

        do {
            try await manager.forget(main) { _ in }
            XCTFail("expected throw")
        } catch let error as ArcMountError {
            XCTAssertEqual(error, .mainMountProtected)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(runner.callLines.isEmpty)
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что падает**

Run: `swift test --filter ArcMountsTests 2>&1 | tail -5`

- [ ] **Step 3: Реализация**

`Sources/XcodeCleanerCore/ArcMounts.swift`:

```swift
import Foundation

public struct ArcMount: Sendable, Equatable, Identifiable, Decodable, Hashable {
    public enum Status: String, Sendable, Decodable, Hashable {
        case mounted
        case unmounted
    }

    public let status: Status
    public let mount: String
    public let store: String
    public let objectStore: String

    public init(status: Status, mount: String, store: String, objectStore: String) {
        self.status = status
        self.mount = mount
        self.store = store
        self.objectStore = objectStore
    }

    enum CodingKeys: String, CodingKey {
        case status
        case mount
        case store
        case objectStore = "object-store"
    }

    public var id: String { mount }
    public var name: String { URL(fileURLWithPath: mount).lastPathComponent }
    public var isMounted: Bool { status == .mounted }

    public static func parse(_ data: Data) throws -> [ArcMount] {
        try JSONDecoder().decode([ArcMount].self, from: data)
    }
}

public struct ArcMountInfo: Sendable, Equatable, Identifiable, Hashable {
    public let mount: ArcMount
    public let storeSizeBytes: Int64?
    public let isMain: Bool
    public let sharesMainObjectStore: Bool

    public var id: String { mount.id }
}

public enum ArcMountError: Error, Equatable, Sendable {
    case invalidName(String)
    case directoryNotEmpty(String)
    case mainMountNotFound
    case mainMountProtected
    case commandFailed(String, String)
}

public struct ArcMountManager: Sendable {
    public typealias Log = @Sendable (String) -> Void

    private let runner: any CommandRunning
    private let home: URL
    private let fileManager: FileManager

    public init(runner: any CommandRunning, home: URL, fileManager: FileManager = .default) {
        self.runner = runner
        self.home = home.standardizedFileURL
        self.fileManager = fileManager
    }

    public var mainMountPath: String { home.appendingPathComponent("arcadia").path }

    public func list() async throws -> [ArcMountInfo] {
        let result = try await runner.run("arc", ["mount", "--list", "--json"], currentDirectory: home, onOutputLine: nil)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc mount --list", result.stderr)
        }
        let mounts = try ArcMount.parse(Data(result.stdout.utf8))
        let main = mounts.first { $0.mount == mainMountPath }
        return mounts
            .sorted { $0.mount < $1.mount }
            .map { mount in
                let isMain = mount.mount == mainMountPath
                return ArcMountInfo(
                    mount: mount,
                    storeSizeBytes: isMain ? nil : DirectorySizer.size(of: URL(fileURLWithPath: mount.store), fileManager: fileManager),
                    isMain: isMain,
                    sharesMainObjectStore: main.map { $0.objectStore == mount.objectStore } ?? false
                )
            }
    }

    public func mountPath(forName name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/ \t\n")
        guard trimmed.isEmpty == false,
              trimmed != "..",
              trimmed.rangeOfCharacter(from: forbidden) == nil
        else {
            throw ArcMountError.invalidName(name)
        }
        return home.appendingPathComponent("arcadia_\(trimmed)")
    }

    @discardableResult
    public func mountNew(name: String, log: Log) async throws -> URL {
        let path = try mountPath(forName: name)
        if fileManager.fileExists(atPath: path.path) {
            let contents = try fileManager.contentsOfDirectory(atPath: path.path)
            guard contents.isEmpty else {
                throw ArcMountError.directoryNotEmpty(path.path)
            }
        }
        let infos = try await list()
        guard let main = infos.first(where: \.isMain) else {
            throw ArcMountError.mainMountNotFound
        }
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        log("mkdir -p \(path.path)")
        let arguments = ["mount", "-m", path.path, "--object-store", main.mount.objectStore, "--override-object-store"]
        log("arc \(arguments.joined(separator: " "))")
        let result = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc mount", result.stderr)
        }
        return path
    }

    public func unmount(_ mountPath: String, force: Bool, log: Log) async throws {
        var arguments = ["unmount"]
        if force { arguments.append("--force") }
        arguments.append(mountPath)
        log("arc \(arguments.joined(separator: " "))")
        let result = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc unmount", result.stderr)
        }
    }

    public func forget(_ mount: ArcMount, log: Log) async throws {
        guard mount.mount != mainMountPath else {
            throw ArcMountError.mainMountProtected
        }
        if mount.isMounted {
            try await unmount(mount.mount, force: false, log: log)
        }
        let arguments = ["unmount", "--forget", mount.mount]
        log("arc \(arguments.joined(separator: " "))")
        let result = try await runner.run("arc", arguments, currentDirectory: home, onOutputLine: log)
        guard result.succeeded else {
            throw ArcMountError.commandFailed("arc unmount --forget", result.stderr)
        }
        removeEmptyMountDirectory(mount.mount, log: log)
    }

    private func removeEmptyMountDirectory(_ path: String, log: Log) {
        guard fileManager.fileExists(atPath: path) else { return }
        let contents = (try? fileManager.contentsOfDirectory(atPath: path)) ?? ["?"]
        guard contents.isEmpty else {
            log("Папка \(path) не пуста, оставлена на месте")
            return
        }
        do {
            try fileManager.removeItem(atPath: path)
            log("rmdir \(path)")
        } catch {
            log("Не удалось удалить пустую папку \(path): \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter ArcMountsTests 2>&1 | tail -5`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add Arcadia mount listing and management"
```

---

### Task 11: ProjectCaches

**Files:**
- Create: `Sources/XcodeCleanerCore/ProjectCaches.swift`
- Create: `Tests/XcodeCleanerCoreTests/ProjectCachesTests.swift`

- [ ] **Step 1: Падающий тест**

```swift
import XCTest
@testable import XcodeCleanerCore

final class ProjectCachesTests: XCTestCase {
    func test_collectsOnlyExistingSubpathsOfMountedMounts() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let mounted = try temp.makeDirectory("arcadia_A")
        try temp.makeFile("arcadia_A/mobile/saft/ios/Tuist/.build/x", bytes: 10)
        try temp.makeFile("arcadia_A/mobile/saft/ios/Derived/y", bytes: 10)
        let unmounted = try temp.makeDirectory("arcadia_B")
        try temp.makeFile("arcadia_B/mobile/saft/ios/Tuist/.build/z", bytes: 10)
        let global = try temp.makeDirectory(".cache/tuist")
        let paths = CachePaths(home: temp.url)
        let mounts = [
            ArcMountInfo(mount: ArcMount(status: .mounted, mount: mounted.path, store: "/s", objectStore: "/o"), storeSizeBytes: nil, isMain: true, sharesMainObjectStore: true),
            ArcMountInfo(mount: ArcMount(status: .unmounted, mount: unmounted.path, store: "/s", objectStore: "/o"), storeSizeBytes: 0, isMain: false, sharesMainObjectStore: true),
        ]

        let items = ProjectCacheScanner.items(mounts: mounts, cachePaths: paths)
        let allowlist = ProjectCacheScanner.allowedDirectories(mounts: mounts, cachePaths: paths)

        XCTAssertEqual(Set(items.map(\.id)), [
            global.path,
            mounted.appendingPathComponent("mobile/saft/ios/Tuist/.build").path,
            mounted.appendingPathComponent("mobile/saft/ios/Derived").path,
        ])
        XCTAssertTrue(items.allSatisfy { $0.kind == .projectCaches })
        XCTAssertEqual(allowlist.count, 1 + 3)
        XCTAssertTrue(allowlist.contains(mounted.appendingPathComponent("mobile/saft/ios/DerivedData")))
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что падает**

Run: `swift test --filter ProjectCachesTests 2>&1 | tail -5`

- [ ] **Step 3: Реализация**

`Sources/XcodeCleanerCore/ProjectCaches.swift`:

```swift
import Foundation

public enum ProjectCacheScanner {
    public static func allowedDirectories(mounts: [ArcMountInfo], cachePaths: CachePaths) -> [URL] {
        let inMounts = mounts
            .filter { $0.mount.isMounted }
            .flatMap { cachePaths.projectCacheDirectories(inMount: URL(fileURLWithPath: $0.mount.mount)) }
        return cachePaths.globalProjectCaches + inMounts
    }

    public static func items(
        mounts: [ArcMountInfo],
        cachePaths: CachePaths,
        fileManager: FileManager = .default
    ) -> [CleanupItem] {
        CacheItemBuilder.items(
            kind: .projectCaches,
            directories: allowedDirectories(mounts: mounts, cachePaths: cachePaths),
            fileManager: fileManager
        )
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter ProjectCachesTests 2>&1 | tail -5`
Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add project cache scanner for Arcadia mounts"
```

---

### Task 12: RunningAppsCheck и CleanupLogFile

**Files:**
- Create: `Sources/XcodeCleanerCore/RunningAppsCheck.swift`
- Create: `Sources/XcodeCleanerCore/CleanupLogFile.swift`
- Create: `Tests/XcodeCleanerCoreTests/RunningAppsCheckTests.swift`
- Create: `Tests/XcodeCleanerCoreTests/CleanupLogFileTests.swift`

- [ ] **Step 1: Падающие тесты**

`Tests/XcodeCleanerCoreTests/RunningAppsCheckTests.swift`:

```swift
import XCTest
@testable import XcodeCleanerCore

final class RunningAppsCheckTests: XCTestCase {
    func test_reportsRunningProcessesByName() async {
        let runner = FakeCommandRunner()
        runner.defaultResult = CommandResult(exitCode: 1, stdout: "", stderr: "")
        runner.respond(to: "pgrep -x Xcode", stdout: "123")
        runner.respond(to: "pgrep -x xcodebuild", stdout: "456")
        let check = RunningAppsCheck(runner: runner)

        let running = await check.blockingProcesses()

        XCTAssertEqual(running, ["Xcode", "xcodebuild"])
        XCTAssertEqual(runner.callLines, [
            "pgrep -x Xcode", "pgrep -x Simulator", "pgrep -x xcodebuild", "pgrep -x xctest",
        ])
    }

    func test_emptyWhenNothingRuns() async {
        let runner = FakeCommandRunner()
        runner.defaultResult = CommandResult(exitCode: 1, stdout: "", stderr: "")
        let check = RunningAppsCheck(runner: runner)

        let running = await check.blockingProcesses()

        XCTAssertEqual(running, [])
    }
}
```

`Tests/XcodeCleanerCoreTests/CleanupLogFileTests.swift`:

```swift
import XCTest
@testable import XcodeCleanerCore

final class CleanupLogFileTests: XCTestCase {
    func test_appendsLinesToFileInDirectory() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let log = try CleanupLogFile(directory: temp.url, runID: "test-run")

        await log.append("first")
        await log.append("second")

        let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertEqual(contents, "first\nsecond\n")
        XCTAssertEqual(log.fileURL.lastPathComponent, "cleanup-test-run.log")
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что падает**

Run: `swift test --filter 'RunningAppsCheckTests|CleanupLogFileTests' 2>&1 | tail -5`

- [ ] **Step 3: Реализация**

`Sources/XcodeCleanerCore/RunningAppsCheck.swift`:

```swift
import Foundation

public struct RunningAppsCheck: Sendable {
    public static let watchedProcesses = ["Xcode", "Simulator", "xcodebuild", "xctest"]

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func blockingProcesses() async -> [String] {
        var running: [String] = []
        for name in Self.watchedProcesses {
            if let result = try? await runner.run("pgrep", ["-x", name]), result.succeeded {
                running.append(name)
            }
        }
        return running
    }
}
```

`Sources/XcodeCleanerCore/CleanupLogFile.swift`:

```swift
import Foundation

public actor CleanupLogFile {
    public nonisolated let fileURL: URL
    private let handle: FileHandle

    public init(directory: URL, runID: String = Self.defaultRunID()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("cleanup-\(runID).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
    }

    public static func defaultRunID(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: now)
    }

    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Desktop/Xcode Cleanup Logs")
    }

    public func append(_ line: String) {
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }

    deinit {
        try? handle.close()
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter 'RunningAppsCheckTests|CleanupLogFileTests' 2>&1 | tail -5`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Add running apps check and log file writer"
```

---

### Task 13: Scanner и Cleaner

**Files:**
- Create: `Sources/XcodeCleanerCore/Scanner.swift`
- Create: `Sources/XcodeCleanerCore/Cleaner.swift`
- Create: `Tests/XcodeCleanerCoreTests/CleanerTests.swift`

- [ ] **Step 1: Падающие тесты**

```swift
import XCTest
@testable import XcodeCleanerCore

final class CleanerTests: XCTestCase {
    private func idleRunner() -> FakeCommandRunner {
        let runner = FakeCommandRunner()
        runner.defaultResult = CommandResult(exitCode: 0, stdout: "", stderr: "")
        for name in RunningAppsCheck.watchedProcesses {
            runner.respond(to: "pgrep -x \(name)", exitCode: 1)
        }
        return runner
    }

    func test_orderedFollowsKindExecutionOrder() {
        let items = [
            CleanupItem(id: "p", kind: .projectCaches, title: "", subtitle: "", action: .clearContents(URL(fileURLWithPath: "/p")), sizeBytes: nil, isDestructive: false),
            CleanupItem(id: "a", kind: .archives, title: "", subtitle: "", action: .trash(URL(fileURLWithPath: "/a")), sizeBytes: nil, isDestructive: true),
            CleanupItem(id: "x", kind: .xcodeCaches, title: "", subtitle: "", action: .clearContents(URL(fileURLWithPath: "/x")), sizeBytes: nil, isDestructive: false),
        ]

        XCTAssertEqual(Cleaner.ordered(items).map(\.id), ["x", "a", "p"])
    }

    func test_refusesToRunWhenXcodeIsOpen() async throws {
        let runner = idleRunner()
        runner.respond(to: "pgrep -x Xcode", stdout: "1", exitCode: 0)
        let cleaner = Cleaner(runner: runner, deleter: SafeDeleter(clearableDirectories: [], trashableParents: []), home: FileManager.default.temporaryDirectory)

        do {
            _ = try await cleaner.run([]) { _ in }
            XCTFail("expected throw")
        } catch let error as CleanerError {
            XCTAssertEqual(error, .blockingProcesses(["Xcode"]))
        }
    }

    func test_runsItemsInOrderAndReportsResults() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let cache = try temp.makeDirectory("DerivedData")
        try temp.makeFile("DerivedData/junk", bytes: 10)
        let archivesDir = try temp.makeDirectory("Archives")
        let archive = try temp.makeFile("Archives/Old.xcarchive", bytes: 10)
        let notAllowed = try temp.makeDirectory("NotAllowed")
        let runner = idleRunner()
        let deleter = SafeDeleter(clearableDirectories: [cache], trashableParents: [archivesDir])
        let cleaner = Cleaner(runner: runner, deleter: deleter, home: temp.url)
        let items = [
            CleanupItem(id: "sim", kind: .simulators, title: "", subtitle: "", action: .simulators(.deleteAllAndRuntimes), sizeBytes: nil, isDestructive: true),
            CleanupItem(id: "cache", kind: .xcodeCaches, title: "", subtitle: "", action: .clearContents(cache), sizeBytes: nil, isDestructive: false),
            CleanupItem(id: "bad", kind: .projectCaches, title: "", subtitle: "", action: .clearContents(notAllowed), sizeBytes: nil, isDestructive: false),
            CleanupItem(id: "archive", kind: .archives, title: "", subtitle: "", action: .trash(archive), sizeBytes: nil, isDestructive: true),
        ]
        let logged = LineCollector()

        let report = try await cleaner.run(items) { logged.append($0) }

        XCTAssertEqual(report.results.map(\.itemID), ["cache", "sim", "archive", "bad"])
        XCTAssertEqual(report.results.map(\.succeeded), [true, true, true, false])
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertNotNil(report.diskBefore)
        XCTAssertNotNil(report.diskAfter)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notAllowed.path))
        let simctlCalls = runner.callLines.filter { $0.hasPrefix("xcrun simctl") }
        XCTAssertEqual(simctlCalls, [
            "xcrun simctl shutdown all",
            "xcrun simctl delete unavailable",
            "xcrun simctl runtime dyld_shared_cache remove --all",
            "xcrun simctl delete all",
            "xcrun simctl runtime delete all",
        ])
        XCTAssertEqual(runner.callLines.last, "sync")
        XCTAssertTrue(logged.contains("NotAllowed"))
    }

    func test_eraseAllModeUsesEraseCommand() async throws {
        let runner = idleRunner()
        let cleaner = Cleaner(runner: runner, deleter: SafeDeleter(clearableDirectories: [], trashableParents: []), home: FileManager.default.temporaryDirectory)
        let item = CleanupItem(id: "sim", kind: .simulators, title: "", subtitle: "", action: .simulators(.eraseAll), sizeBytes: nil, isDestructive: true)

        _ = try await cleaner.run([item]) { _ in }

        let simctlCalls = runner.callLines.filter { $0.hasPrefix("xcrun simctl") }
        XCTAssertEqual(simctlCalls, [
            "xcrun simctl shutdown all",
            "xcrun simctl delete unavailable",
            "xcrun simctl runtime dyld_shared_cache remove --all",
            "xcrun simctl erase all",
        ])
    }

    func test_simctlFailureMarksItemFailed() async throws {
        let runner = idleRunner()
        runner.respond(to: "xcrun simctl delete unavailable", stderr: "boom", exitCode: 1)
        let cleaner = Cleaner(runner: runner, deleter: SafeDeleter(clearableDirectories: [], trashableParents: []), home: FileManager.default.temporaryDirectory)
        let item = CleanupItem(id: "sim", kind: .simulators, title: "", subtitle: "", action: .simulators(.deleteUnavailable), sizeBytes: nil, isDestructive: false)

        let report = try await cleaner.run([item]) { _ in }

        XCTAssertEqual(report.results[0].succeeded, false)
        XCTAssertEqual(report.results[0].message, "simctl delete unavailable: boom")
    }
}
```

- [ ] **Step 2: Запустить, убедиться, что падает**

Run: `swift test --filter CleanerTests 2>&1 | tail -5`

- [ ] **Step 3: Реализация Scanner**

`Sources/XcodeCleanerCore/Scanner.swift`:

```swift
import Foundation

public struct ScanResult: Sendable, Equatable {
    public var cacheItems: [CleanupItem] = []
    public var projectCacheItems: [CleanupItem] = []
    public var simulators: SimulatorInventory?
    public var archives: [ArchiveEntry] = []
    public var xcodes: [XcodeInstallation] = []
    public var toolchains: [ToolchainEntry] = []
    public var mounts: [ArcMountInfo] = []
    public var disk: DiskSpace?
    public var warnings: [String] = []

    public init() {}
}

public struct Scanner: Sendable {
    private let runner: any CommandRunning
    private let cachePaths: CachePaths
    private let fileManager: FileManager

    public init(runner: any CommandRunning, cachePaths: CachePaths, fileManager: FileManager = .default) {
        self.runner = runner
        self.cachePaths = cachePaths
        self.fileManager = fileManager
    }

    public func scan() async -> ScanResult {
        var result = ScanResult()
        result.disk = try? DiskSpace.current(for: cachePaths.home)

        async let caches = scanCaches()
        async let simulators = scanSimulators()
        async let archives = ArchiveScanner.archives(in: cachePaths.archivesDirectory, fileManager: fileManager)
        async let xcodes = scanXcodes()
        async let toolchains = XcodeInstallationScanner.toolchains(in: cachePaths.toolchainsDirectory, fileManager: fileManager)
        async let mounts = scanMounts()

        result.cacheItems = await caches
        let (inventory, simulatorWarning) = await simulators
        result.simulators = inventory
        result.archives = await archives
        let (installations, xcodeWarning) = await xcodes
        result.xcodes = installations
        result.toolchains = await toolchains
        let (mountInfos, mountWarning) = await mounts
        result.mounts = mountInfos
        result.projectCacheItems = ProjectCacheScanner.items(mounts: mountInfos, cachePaths: cachePaths, fileManager: fileManager)
        result.warnings = [simulatorWarning, xcodeWarning, mountWarning].compactMap { $0 }
        return result
    }

    public func makeDeleter(for result: ScanResult) -> SafeDeleter {
        SafeDeleter(
            clearableDirectories: cachePaths.allClearable
                + ProjectCacheScanner.allowedDirectories(mounts: result.mounts, cachePaths: cachePaths),
            trashableParents: [cachePaths.applicationsDirectory, cachePaths.toolchainsDirectory]
                + Array(Set(result.archives.map { $0.url.deletingLastPathComponent() }))
        )
    }

    private func scanCaches() async -> [CleanupItem] {
        CacheItemBuilder.items(kind: .xcodeCaches, directories: cachePaths.xcodeCaches, fileManager: fileManager)
            + CacheItemBuilder.items(kind: .deviceSupport, directories: cachePaths.deviceSupport, fileManager: fileManager)
            + CacheItemBuilder.items(kind: .simulatorCaches, directories: cachePaths.simulatorCaches, fileManager: fileManager)
    }

    private func scanSimulators() async -> (SimulatorInventory?, String?) {
        do {
            return (try await SimulatorScanner(runner: runner).inventory(), nil)
        } catch {
            return (nil, "Симуляторы недоступны: \(error)")
        }
    }

    private func scanXcodes() async -> ([XcodeInstallation], String?) {
        do {
            let active = try await XcodeInstallationScanner.activeDeveloperDir(runner: runner)
            let installations = XcodeInstallationScanner.installations(
                in: cachePaths.applicationsDirectory,
                activeDeveloperDir: active,
                fileManager: fileManager
            )
            return (installations, nil)
        } catch {
            return ([], "xcode-select недоступен: \(error)")
        }
    }

    private func scanMounts() async -> ([ArcMountInfo], String?) {
        do {
            let manager = ArcMountManager(runner: runner, home: cachePaths.home, fileManager: fileManager)
            return (try await manager.list(), nil)
        } catch {
            return ([], "arc недоступен: \(error)")
        }
    }
}
```

- [ ] **Step 4: Реализация Cleaner**

`Sources/XcodeCleanerCore/Cleaner.swift`:

```swift
import Foundation

public struct ItemResult: Sendable, Equatable, Identifiable {
    public let itemID: String
    public let succeeded: Bool
    public let message: String?

    public var id: String { itemID }
}

public struct CleanupReport: Sendable, Equatable {
    public let diskBefore: DiskSpace?
    public let diskAfter: DiskSpace?
    public let results: [ItemResult]

    public var failureCount: Int { results.filter { $0.succeeded == false }.count }

    public var freedBytes: Int64? {
        guard let diskBefore, let diskAfter else { return nil }
        return diskAfter.available - diskBefore.available
    }
}

public enum CleanerError: Error, Equatable, Sendable {
    case blockingProcesses([String])
}

public struct Cleaner: Sendable {
    public typealias Log = @Sendable (String) -> Void

    private let runner: any CommandRunning
    private let deleter: SafeDeleter
    private let fileManager: FileManager
    private let home: URL

    public init(runner: any CommandRunning, deleter: SafeDeleter, fileManager: FileManager = .default, home: URL) {
        self.runner = runner
        self.deleter = deleter
        self.fileManager = fileManager
        self.home = home
    }

    public static func ordered(_ items: [CleanupItem]) -> [CleanupItem] {
        let rank = Dictionary(uniqueKeysWithValues: CleanupKind.executionOrder.enumerated().map { ($1, $0) })
        return items.sorted { (rank[$0.kind] ?? .max, $0.id) < (rank[$1.kind] ?? .max, $1.id) }
    }

    public func run(_ items: [CleanupItem], log: @escaping Log) async throws -> CleanupReport {
        let blocking = await RunningAppsCheck(runner: runner).blockingProcesses()
        guard blocking.isEmpty else {
            throw CleanerError.blockingProcesses(blocking)
        }

        let ordered = Self.ordered(items)
        let diskBefore = try? DiskSpace.current(for: home)
        log("Начало: \(Date().formatted(date: .numeric, time: .standard))")
        if let diskBefore {
            log("Свободно до: \(ByteFormatting.string(diskBefore.available))")
        }

        let touchesSimulators = ordered.contains { $0.kind == .simulators || $0.kind == .simulatorCaches }
        if touchesSimulators {
            _ = await simctl(["shutdown", "all"], log: log)
        }

        var results: [ItemResult] = []
        for item in ordered {
            log("→ \(item.kind.title): \(item.title)")
            let result = await perform(item, log: log)
            if let message = result.message {
                log(result.succeeded ? "  \(message)" : "  ✗ \(message)")
            }
            results.append(result)
        }

        _ = try? await runner.run("sync", [])
        let diskAfter = try? DiskSpace.current(for: home)
        let report = CleanupReport(diskBefore: diskBefore, diskAfter: diskAfter, results: results)
        if let diskAfter {
            log("Свободно после: \(ByteFormatting.string(diskAfter.available))")
        }
        if let freed = report.freedBytes {
            log("Освободилось по факту: \(ByteFormatting.string(freed))")
        }
        log("Ошибок: \(report.failureCount)")
        return report
    }

    private func perform(_ item: CleanupItem, log: Log) async -> ItemResult {
        switch item.action {
        case let .clearContents(directory):
            do {
                let failures = try deleter.clearContents(of: directory, fileManager: fileManager)
                for failure in failures {
                    log("  ✗ \(failure.path): \(failure.reason)")
                }
                return ItemResult(
                    itemID: item.id,
                    succeeded: failures.isEmpty,
                    message: failures.isEmpty ? nil : "\(failures.count) объектов не удалено"
                )
            } catch {
                return ItemResult(itemID: item.id, succeeded: false, message: "\(directory.path): \(error)")
            }
        case let .trash(url):
            do {
                try deleter.trash(url, fileManager: fileManager)
                return ItemResult(itemID: item.id, succeeded: true, message: "в Корзину")
            } catch {
                return ItemResult(itemID: item.id, succeeded: false, message: "\(url.path): \(error)")
            }
        case let .simulators(mode):
            return await performSimulators(mode, itemID: item.id, log: log)
        }
    }

    private func performSimulators(_ mode: SimulatorMode, itemID: String, log: Log) async -> ItemResult {
        var commands: [[String]] = [
            ["delete", "unavailable"],
            ["runtime", "dyld_shared_cache", "remove", "--all"],
        ]
        switch mode {
        case .deleteUnavailable:
            break
        case .eraseAll:
            commands.append(["erase", "all"])
        case .deleteAll:
            commands.append(["delete", "all"])
        case .deleteAllAndRuntimes:
            commands.append(["delete", "all"])
            commands.append(["runtime", "delete", "all"])
        }
        var failures: [String] = []
        for command in commands {
            if let failure = await simctl(command, log: log) {
                failures.append(failure)
            }
        }
        return ItemResult(
            itemID: itemID,
            succeeded: failures.isEmpty,
            message: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
    }

    private func simctl(_ arguments: [String], log: Log) async -> String? {
        let label = "simctl \(arguments.joined(separator: " "))"
        log("  \(label)")
        do {
            let result = try await runner.run("xcrun", ["simctl"] + arguments, onOutputLine: { log("    \($0)") })
            guard result.succeeded else {
                return "\(label): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return nil
        } catch {
            return "\(label): \(error)"
        }
    }
}
```

- [ ] **Step 5: Прогнать все тесты**

Run: `swift test 2>&1 | tail -5`
Expected: все тесты зелёные, `with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "Add Scanner composition and Cleaner execution"
```

---

### Task 14: AppModel

**Files:**
- Create: `Sources/XcodeCleaner/AppModel.swift`

- [ ] **Step 1: Написать AppModel**

```swift
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
    private let scanner: Scanner
    private let mountManager: ArcMountManager
    private var logFile: CleanupLogFile?

    init(runner: any CommandRunning = ProcessCommandRunner(), cachePaths: CachePaths = CachePaths()) {
        self.runner = runner
        self.cachePaths = cachePaths
        scanner = Scanner(runner: runner, cachePaths: cachePaths)
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
            ConfirmEntry(id: $0.id, title: "\($0.kind.title): \($0.title)", sizeBytes: $0.sizeBytes, isDestructive: $0.isDestructive)
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
            ConfirmEntry(id: $0.id, title: "Arcadia: \($0.mount.name)", sizeBytes: $0.storeSizeBytes, isDestructive: true)
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
        } catch let error as CleanerError {
            if case let .blockingProcesses(names) = error {
                errorMessage = "Сначала закройте: \(names.joined(separator: ", "))"
            }
        } catch let error as ArcMountError {
            errorMessage = describe(error)
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func describe(_ error: ArcMountError) -> String {
        switch error {
        case let .invalidName(name): "Недопустимое имя маунта: \"\(name)\""
        case let .directoryNotEmpty(path): "Папка уже существует и не пуста: \(path)"
        case .mainMountNotFound: "Основной маунт ~/arcadia не найден"
        case .mainMountProtected: "Основной маунт ~/arcadia удалить нельзя"
        case let .commandFailed(command, stderr): "\(command) завершилась с ошибкой: \(stderr)"
        }
    }

    func log(_ line: String) {
        logLines.append(line)
        if logFile == nil {
            logFile = try? CleanupLogFile(directory: CleanupLogFile.defaultDirectory(home: cachePaths.home))
        }
        if let logFile {
            Task { await logFile.append(line) }
        }
    }
}
```

- [ ] **Step 2: Собрать**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` без ошибок и предупреждений про Sendable.

- [ ] **Step 3: Commit**

```bash
git add Sources
git commit -m "Add AppModel"
```

---

### Task 15: Views

**Files:**
- Modify: `Sources/XcodeCleaner/XcodeCleanerApp.swift`
- Create: `Sources/XcodeCleaner/Views/RootView.swift`
- Create: `Sources/XcodeCleaner/Views/DiskHeaderView.swift`
- Create: `Sources/XcodeCleaner/Views/XcodeSectionView.swift`
- Create: `Sources/XcodeCleaner/Views/ArcadiaSectionView.swift`
- Create: `Sources/XcodeCleaner/Views/LogView.swift`
- Create: `Sources/XcodeCleaner/Views/ConfirmSheet.swift`

- [ ] **Step 1: Точка входа**

`Sources/XcodeCleaner/XcodeCleanerApp.swift`:

```swift
import SwiftUI

@main
struct XcodeCleanerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("XcodeCleaner") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
```

- [ ] **Step 2: DiskHeaderView**

`Sources/XcodeCleaner/Views/DiskHeaderView.swift`:

```swift
import SwiftUI
import XcodeCleanerCore

struct DiskHeaderView: View {
    let disk: DiskSpace?
    let bytesToFree: Int64
    let lastReport: CleanupReport?

    var body: some View {
        HStack(spacing: 24) {
            metric("Свободно", disk.map { ByteFormatting.string($0.available) })
            metric("Занято", disk.map { ByteFormatting.string($0.used) })
            metric("Всего", disk.map { ByteFormatting.string($0.total) })
            Divider().frame(height: 32)
            metric("Освободится", ByteFormatting.string(bytesToFree), highlighted: bytesToFree > 0)
            if let freed = lastReport?.freedBytes {
                Divider().frame(height: 32)
                metric("Последняя очистка", ByteFormatting.string(freed))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func metric(_ title: String, _ value: String?, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.title3.monospacedDigit())
                .fontWeight(highlighted ? .semibold : .regular)
                .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
        }
    }
}
```

- [ ] **Step 3: XcodeSectionView**

`Sources/XcodeCleaner/Views/XcodeSectionView.swift`:

```swift
import SwiftUI
import XcodeCleanerCore

struct XcodeSectionView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            ForEach(CleanupKind.executionOrder) { kind in
                Section {
                    controls(for: kind)
                    let group = model.items(for: kind)
                    if group.isEmpty {
                        Text("Нечего чистить")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group) { item in
                        row(item)
                    }
                } header: {
                    header(for: kind)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.isScanning {
                ProgressView("Сканирование…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func header(for kind: CleanupKind) -> some View {
        HStack {
            Toggle(kind.title, isOn: Binding(
                get: { model.isGroupSelected(kind) },
                set: { model.setSelected(kind: kind, $0) }
            ))
            .toggleStyle(.checkbox)
            .font(.headline)
            Spacer()
            Text(ByteFormatting.string(model.items(for: kind).reduce(0) { $0 + ($1.sizeBytes ?? 0) }))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(for kind: CleanupKind) -> some View {
        switch kind {
        case .simulators:
            Picker("Режим", selection: $model.simulatorMode) {
                ForEach(SimulatorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
        case .archives:
            Stepper("Старше \(model.archiveMaxAgeDays) дней", value: $model.archiveMaxAgeDays, in: 0...365, step: 5)
        default:
            EmptyView()
        }
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { model.isSelected(item) },
                set: { _ in model.toggle(item) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                        if item.isDestructive {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Данные не регенерируются")
                        }
                    }
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Text(item.sizeBytes.map(ByteFormatting.string) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 4: ArcadiaSectionView**

`Sources/XcodeCleaner/Views/ArcadiaSectionView.swift`:

```swift
import SwiftUI
import XcodeCleanerCore

struct ArcadiaSectionView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Имя нового маунта, например SAFTIOS-1234", text: $model.newMountName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.mountNew() } }
                Button("Смонтировать") {
                    Task { await model.mountNew() }
                }
                .disabled(model.newMountName.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
                Spacer()
                Button("Размонтировать выбранные") {
                    Task { await model.unmountSelected() }
                }
                .disabled(model.selectedMounts.contains { $0.mount.isMounted } == false || model.isWorking)
                Button("Удалить выбранные", role: .destructive) {
                    model.requestDeleteMounts()
                }
                .disabled(model.selectedMounts.isEmpty || model.isWorking)
            }
            .padding(12)

            Table(model.scan.mounts, selection: $model.selectedMountIDs) {
                TableColumn("Маунт") { info in
                    HStack(spacing: 6) {
                        if info.isMain {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        }
                        Text(info.mount.name)
                    }
                    .help(info.mount.mount)
                }
                TableColumn("Статус") { info in
                    Text(info.mount.isMounted ? "mounted" : "unmounted")
                        .foregroundStyle(info.mount.isMounted ? .green : .secondary)
                }
                .width(90)
                TableColumn("Store") { info in
                    Text(info.storeSizeBytes.map(ByteFormatting.string) ?? "—")
                        .monospacedDigit()
                }
                .width(100)
                TableColumn("Object store") { info in
                    Text(info.sharesMainObjectStore ? "общий" : "свой")
                        .foregroundStyle(.secondary)
                }
                .width(90)
            }

            if let retryPath = model.unmountRetryPath {
                HStack {
                    Text("arc отказался размонтировать \(retryPath)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Повторить с --force") {
                        Task { await model.retryUnmountWithForce() }
                    }
                }
                .padding(12)
                .background(.yellow.opacity(0.15))
            }
        }
    }
}
```

- [ ] **Step 5: LogView и ConfirmSheet**

`Sources/XcodeCleaner/Views/LogView.swift`:

```swift
import SwiftUI

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}
```

`Sources/XcodeCleaner/Views/ConfirmSheet.swift`:

```swift
import SwiftUI
import XcodeCleanerCore

struct ConfirmSheet: View {
    let confirmation: Confirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(confirmation.title)
                .font(.title2)
            List(confirmation.entries) { entry in
                HStack {
                    if entry.isDestructive {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(entry.sizeBytes.map(ByteFormatting.string) ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 200)
            HStack {
                Text("Итого: \(ByteFormatting.string(confirmation.totalBytes))")
                    .font(.headline)
                Spacer()
            }
            if confirmation.hasDestructive {
                Toggle("Понимаю, что отмеченные ⚠︎ данные не регенерируются и не восстанавливаются автоматически", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Удалить", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmation.hasDestructive && acknowledged == false)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
```

- [ ] **Step 6: RootView**

`Sources/XcodeCleaner/Views/RootView.swift`:

```swift
import SwiftUI
import XcodeCleanerCore

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: sectionBinding) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(160)
        } detail: {
            VStack(spacing: 0) {
                DiskHeaderView(disk: model.scan.disk, bytesToFree: model.bytesToFree, lastReport: model.lastReport)
                Divider()
                content
                Divider()
                footer
            }
        }
        .task { await model.rescan() }
        .sheet(item: $model.pendingConfirmation) { confirmation in
            ConfirmSheet(
                confirmation: confirmation,
                onConfirm: {
                    Task {
                        switch confirmation.kind {
                        case .cleanup: await model.confirmCleanup()
                        case .deleteMounts: await model.confirmDeleteMounts()
                        }
                    }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        }
        .alert("Ошибка", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if $0 == false { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sectionBinding: Binding<AppModel.Section?> {
        Binding(get: { model.section }, set: { model.section = $0 ?? .xcode })
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .xcode: XcodeSectionView(model: model)
        case .arcadia: ArcadiaSectionView(model: model)
        case .log: LogView(lines: model.logLines)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await model.rescan() }
            } label: {
                Label("Пересканировать", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning || model.isWorking)
            if model.isWorking {
                ProgressView().controlSize(.small)
                Text("Выполняется…").foregroundStyle(.secondary)
            }
            Spacer()
            Text("Выбрано: \(model.selectedItems.count)")
                .foregroundStyle(.secondary)
            Button("Очистить выбранное", role: .destructive) {
                model.requestCleanup()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(model.selectedItems.isEmpty || model.isWorking || model.isScanning)
        }
        .padding(12)
        .background(.bar)
    }
}
```

- [ ] **Step 7: Собрать и запустить из терминала для smoke-теста**

Run: `swift build 2>&1 | tail -3 && swift run XcodeCleaner`
Expected: окно с тремя разделами, шапка показывает цифры диска, раздел Xcode заполняется после сканирования, раздел Arcadia показывает таблицу маунтов. Закрыть окно (`Cmd+Q`).

- [ ] **Step 8: Commit**

```bash
git add Sources
git commit -m "Add SwiftUI views"
```

---

### Task 16: build.sh, иконка и ручная проверка

**Files:**
- Create: `build.sh`
- Create: `Assets/AppIcon.png` (опционально; 1024×1024)
- Create: `README.md`

- [ ] **Step 1: build.sh**

```bash
#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

readonly APP_NAME="XcodeCleaner"
readonly BUNDLE_ID="dev.ltheresi.xcodecleaner"
readonly VERSION="1.0.0"
readonly MIN_OS="15.0"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR=".build/${APP_NAME}.app"

[[ -d "$APP_DIR" ]] && rm -r "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

ICON_KEY=""
if [[ -f Assets/AppIcon.png ]]; then
  ICONSET=".build/AppIcon.iconset"
  [[ -d "$ICONSET" ]] && rm -r "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Assets/AppIcon.png --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Assets/AppIcon.png --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
  ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
${ICON_KEY}
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR"

DEST="${HOME}/Desktop/${APP_NAME}.app"
[[ -d "$DEST" ]] && rm -r "$DEST"
cp -R "$APP_DIR" "$DEST"
print "Готово: ${DEST}"
```

Run: `chmod +x build.sh && ./build.sh`
Expected: последняя строка `Готово: /Users/ltheresi/Desktop/XcodeCleaner.app`.

- [ ] **Step 2: README**

`README.md`:

```markdown
# XcodeCleaner

macOS-утилита для очистки Xcode, симуляторов и маунтов Arcadia.

## Сборка

    ./build.sh

Собирает release-бинарь через SwiftPM, упаковывает в `XcodeCleaner.app`
и копирует на рабочий стол. Xcode-проект не нужен.

## Тесты

    swift test

## Что чистит

См. `docs/superpowers/specs/2026-09-09-xcode-cleaner-design.md`.
Лог каждого прогона: `~/Desktop/Xcode Cleanup Logs/`.
```

- [ ] **Step 3: Ручная проверка**

1. Открыть `~/Desktop/XcodeCleaner.app` двойным кликом. Ожидание: окно открывается, шапка показывает «Свободно / Занято / Всего», совпадающие с Finder → Get Info для диска (расхождение до 1 GB допустимо).
2. Раздел Xcode: категории заполнены, у DerivedData есть размер. Отметить «Кэши Xcode» целиком. Ожидание: «Освободится» в шапке равен сумме размеров группы.
3. Раздел Arcadia: таблица содержит `arcadia` с замком и без чекбокса-эффекта, размонтированные маунты имеют размер store.
4. Выбрать один заведомо ненужный `unmounted` маунт, нажать «Удалить выбранные». Ожидание: лист подтверждения с ⚠︎ и заблокированной кнопкой до чекбокса; после подтверждения в логе `arc unmount --forget ...` и `rmdir ...`, маунт исчезает из таблицы после пересканирования, `du -sh ~/.arc/stores` уменьшился.
5. При открытом Xcode нажать «Очистить выбранное» с любым пунктом. Ожидание: alert «Сначала закройте: Xcode», ничего не удалено.
6. Закрыть Xcode, повторить с «Кэши Xcode». Ожидание: раздел Лог открылся сам, в конце «Свободно после» и «Освободилось по факту», файл лога появился в `~/Desktop/Xcode Cleanup Logs/`.

- [ ] **Step 4: Commit**

```bash
git add build.sh README.md Assets
git commit -m "Add build script and README"
```

---

## Self-review

- **Spec coverage:** шапка диска (Task 15 DiskHeaderView, `bytesToFree` в Task 14); восемь категорий (Tasks 6, 7, 8, 9, 11); Arcadia mount/unmount/forget (Task 10, 14, 15); лог в файл (Task 12, 14); подтверждение с чекбоксом (Task 15 ConfirmSheet); allowlist и нет `rm -rf` (Task 5); Корзина для Archives/Xcode/toolchains (Task 13 `.trash`); проверка запущенных процессов (Task 12, 13); порядок выполнения (Task 13 `ordered`, `shutdown all` первым); тесты на фикстурах и фейковом runner (Tasks 2–13); `build.sh` (Task 16).
- **Type consistency:** `CleanupItem.Action` (`clearContents`, `trash`, `simulators`) используется одинаково в Tasks 6, 7, 8, 9, 13, 14. `ArcMountInfo(mount:storeSizeBytes:isMain:sharesMainObjectStore:)` совпадает в Tasks 10, 11, 14, 15. `Cleaner.run(_:log:)` и `ArcMountManager.mountNew/unmount/forget(…, log:)` принимают `@Sendable (String) -> Void`; в AppModel передаётся замыкание с `Task { @MainActor in }`.
- **Известное ограничение:** размер store для двух десятков маунтов считается обходом `~/.arc/stores` (около 100 GB мелких файлов), первый скан может занять минуту; результат показывается по завершении, UI не блокируется.
- **Известное ограничение:** `Table` не умеет запрещать выбор отдельной строки, поэтому основной маунт защищён в модели (`selectedMounts` исключает `isMain`, `forget` бросает `mainMountProtected`).
