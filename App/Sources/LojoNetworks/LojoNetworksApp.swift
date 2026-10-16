import SwiftUI

@main
struct LojoNetworksApp: App {
    @StateObject private var store = NetworkStore()
    @StateObject private var remote = RemoteControllerStore(launch: LaunchOptions.current)
    @StateObject private var device = RemoteDeviceRuntime(launch: LaunchOptions.current)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(remote)
                .environmentObject(device)
        }
    }
}
