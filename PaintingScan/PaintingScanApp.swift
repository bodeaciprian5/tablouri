import SwiftUI

@main
struct PaintingScanApp: App {
    @StateObject private var capture = CaptureManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(capture)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
