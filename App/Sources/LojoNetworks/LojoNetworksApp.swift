import SwiftUI

@main
struct LojoNetworksApp: App {
    @StateObject private var store: NetworkStore
    @StateObject private var remote: RemoteControllerStore
    @StateObject private var device: RemoteDeviceRuntime

    init() {
        let store = NetworkStore()
        let launch = LaunchOptions.current
        _store = StateObject(wrappedValue: store)
        _remote = StateObject(wrappedValue: RemoteControllerStore(launch: launch, site: store))
        _device = StateObject(wrappedValue: RemoteDeviceRuntime(launch: launch, site: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(remote)
                .environmentObject(device)
        }
    }
}
