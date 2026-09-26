import XCTest
import XcodeCleanerCore
@testable import XcodeCleaner

/// A suite of its own, never the app's own domain: these tests write the very key the app reads,
/// and writing it into `dev.ltheresi.xcodecleaner` would reconfigure the installed app.
///
/// One fixed suite rather than a fresh name per test. `removePersistentDomain` empties a domain but
/// does not always take its file in `~/Library/Preferences` with it, and a unique name per test
/// would leave a new file behind on every run. The domain is emptied on both sides of a test, so
/// nothing carries over between them.
@MainActor
final class AppModelSearchRootsTests: XCTestCase {
    private static let suiteName = "dev.ltheresi.xcodecleaner.tests"

    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    func test_usesConfiguredRoots() {
        defaults.set(["mobile/saft/ios", "kinopoisk/mobile"], forKey: AppModel.projectSearchRootsKey)

        XCTAssertEqual(
            AppModel.cachePaths(defaults: defaults).projectSearchRoots,
            ["mobile/saft/ios", "kinopoisk/mobile"]
        )
    }

    func test_normalizesConfiguredRoots() {
        defaults.set(
            [" /mobile/saft/ios/ ", "mobile/saft/ios", "", "../escape", "tools"],
            forKey: AppModel.projectSearchRootsKey
        )

        XCTAssertEqual(
            AppModel.cachePaths(defaults: defaults).projectSearchRoots,
            ["mobile/saft/ios", "tools"]
        )
    }

    func test_fallsBackToDefaultsWhenKeyIsAbsent() {
        XCTAssertEqual(
            AppModel.cachePaths(defaults: defaults).projectSearchRoots,
            CachePaths.defaultProjectSearchRoots
        )
    }

    func test_fallsBackToDefaultsWhenListIsEmpty() {
        defaults.set([String](), forKey: AppModel.projectSearchRootsKey)

        XCTAssertEqual(
            AppModel.cachePaths(defaults: defaults).projectSearchRoots,
            CachePaths.defaultProjectSearchRoots
        )
    }

    func test_fallsBackToDefaultsWhenEveryRootIsRejected() {
        defaults.set(["..", "/", "  "], forKey: AppModel.projectSearchRootsKey)

        XCTAssertEqual(
            AppModel.cachePaths(defaults: defaults).projectSearchRoots,
            CachePaths.defaultProjectSearchRoots
        )
    }

    func test_ignoresAValueThatIsNotAListOfStrings() {
        defaults.set("mobile/saft/ios", forKey: AppModel.projectSearchRootsKey)

        XCTAssertEqual(
            AppModel.cachePaths(defaults: defaults).projectSearchRoots,
            CachePaths.defaultProjectSearchRoots
        )
    }

    // MARK: Folders

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }

    func test_readsConfiguredFolders() {
        defaults.set(["~/Developer", "/Volumes/Work/"], forKey: AppModel.projectSearchFoldersKey)

        XCTAssertEqual(
            AppModel.cachePaths(defaults: defaults).projectSearchFolders.map(\.path),
            [home.appendingPathComponent("Developer").path, "/Volumes/Work"]
        )
    }

    func test_dropsRejectedFolders() {
        defaults.set(
            ["/", "Developer", "/System", "~/Developer", "~/Developer/"],
            forKey: AppModel.projectSearchFoldersKey
        )

        XCTAssertEqual(
            AppModel.cachePaths(defaults: defaults).projectSearchFolders.map(\.path),
            [home.appendingPathComponent("Developer").path]
        )
    }

    func test_foldersFallBackToEmptyWhenKeyIsAbsent() {
        XCTAssertEqual(AppModel.cachePaths(defaults: defaults).projectSearchFolders, [])
    }

    func test_foldersFallBackToEmptyWhenValueIsNotAListOfStrings() {
        defaults.set("~/Developer", forKey: AppModel.projectSearchFoldersKey)
        XCTAssertEqual(AppModel.cachePaths(defaults: defaults).projectSearchFolders, [])

        defaults.set([1, 2], forKey: AppModel.projectSearchFoldersKey)
        XCTAssertEqual(AppModel.cachePaths(defaults: defaults).projectSearchFolders, [])
    }

    func test_foldersFallBackToEmptyWhenEveryFolderIsRejected() {
        defaults.set(["/", "relative", "/usr"], forKey: AppModel.projectSearchFoldersKey)

        XCTAssertEqual(AppModel.cachePaths(defaults: defaults).projectSearchFolders, [])
    }

    /// The two lists are independent: folders never replace the Arcadia roots or their defaults.
    func test_foldersLeaveTheRootsAlone() {
        defaults.set(["~/Developer"], forKey: AppModel.projectSearchFoldersKey)

        XCTAssertEqual(
            AppModel.cachePaths(defaults: defaults).projectSearchRoots,
            CachePaths.defaultProjectSearchRoots
        )
    }

    func test_storingWritesNormalizedListsAndRemovesEmptyOnes() {
        AppModel.storeSearchSettings(
            roots: [" /tools/cli/ "],
            folders: ["~/Developer/", "/", "~/Developer"],
            in: defaults
        )

        XCTAssertEqual(defaults.stringArray(forKey: AppModel.projectSearchRootsKey), ["tools/cli"])
        XCTAssertEqual(
            defaults.stringArray(forKey: AppModel.projectSearchFoldersKey),
            [home.appendingPathComponent("Developer").path]
        )

        AppModel.storeSearchSettings(roots: [], folders: [], in: defaults)

        XCTAssertNil(defaults.object(forKey: AppModel.projectSearchRootsKey))
        XCTAssertNil(defaults.object(forKey: AppModel.projectSearchFoldersKey))
    }
}
