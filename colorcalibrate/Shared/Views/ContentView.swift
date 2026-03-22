import SwiftUI

struct ContentView: View {
    var body: some View {
        #if os(macOS)
            MacCalibrationRootView()
        #else
            PhoneCalibrationRootView()
        #endif
    }
}

#Preview {
    ContentView()
}
