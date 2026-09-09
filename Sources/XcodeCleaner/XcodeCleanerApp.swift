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
