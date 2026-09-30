import SwiftUI

@main
struct LojoNetworksApp: App {
    @StateObject private var store = NetworkStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
