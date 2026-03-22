import SwiftUI

@main
struct colorcalibrateApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
            .windowResizability(.contentSize)
        #endif
    }
}
