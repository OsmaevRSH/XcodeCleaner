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
}
