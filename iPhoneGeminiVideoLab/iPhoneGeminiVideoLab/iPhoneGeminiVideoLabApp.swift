import SwiftUI
import MWDATCore

@main
struct iPhoneGeminiVideoLabApp: App {
    init() {
        do {
            try Wearables.configure()
        } catch {
            NSLog("[Meta DAT] Wearables.configure() failed: %@", error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
