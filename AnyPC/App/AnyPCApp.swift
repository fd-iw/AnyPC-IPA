import SwiftUI

@main
struct AnyPCApp: App {
    init() {
        Prefs.register()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
