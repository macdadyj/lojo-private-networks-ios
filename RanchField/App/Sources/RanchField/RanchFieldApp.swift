import SwiftUI

@main
struct RanchFieldApp: App {
    @StateObject private var store = RanchStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
