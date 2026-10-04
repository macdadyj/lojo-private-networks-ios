import SwiftUI

enum AppTab: Hashable {
    case network, activity, map, check, terminal
}

@MainActor
final class Router: ObservableObject {
    @Published var tab: AppTab = .network
    @Published var networkPath: [String] = []
    @Published var mapPath: [String] = []
    @Published var showSettings = false
    @Published var showSetup = false
    @Published var pendingConfirmPin: String?
}

struct RootView: View {
    @EnvironmentObject private var store: NetworkStore
    @StateObject private var router = Router()
    @StateObject private var terminal = TerminalCenter()
    @AppStorage("lojo.onboarded") private var onboarded = false
    @AppStorage("lojo.appearance") private var appearanceRaw = Appearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var watcher = PathWatcher()
    @State private var appliedLaunch = false

    private var appearance: Appearance {
        store.launch.appearance ?? Appearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Group {
            if onboarded {
                tabs
            } else {
                OnboardingView { demo in
                    store.isDemo = demo
                    withAnimation(.easeInOut) { onboarded = true }
                    if !demo { router.showSetup = true }
                    Task { await store.refresh(.launch) }
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .tint(LojoTheme.accent)
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { store.toast = nil }
            }
        }
        .animation(.spring(duration: 0.35), value: store.toast)
        .sheet(item: $store.pendingPairing) { offer in
            NavigationStack {
                PairingView(offer: offer, inSheet: true)
            }
            .interactiveDismissDisabled(store.pairingState == .working)
        }
        .onOpenURL(perform: openPairingLink)
        .task {
            guard store.launch.confirmPairing, let offer = store.pendingPairing else { return }
            try? await Task.sleep(for: .seconds(1.5))
            await store.pair(offer)
        }
        .environmentObject(router)
        .onAppear(perform: applyLaunchOptions)
        .task(id: scenePhase) {
            guard scenePhase == .active, onboarded else { return }
            await store.refresh(.pathChange)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                await store.refresh(.timer)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                terminal.noteScene(inBackground: true)
            case .active:
                terminal.noteScene(inBackground: false)
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onAppear {
            let s = store
            watcher.start {
                Task { await s.refresh(.pathChange) }
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.networkPath) {
                HomeView()
                    .navigationDestination(for: String.self) { key in
                        DeviceDetailView(deviceKey: key)
                    }
            }
            .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
            .tag(AppTab.network)

            NavigationStack {
                ActivityView()
            }
            .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
            .tag(AppTab.activity)

            NavigationStack(path: $router.mapPath) {
                MapScreen()
                    .navigationDestination(for: String.self) { key in
                        DeviceDetailView(deviceKey: key)
                    }
            }
            .tabItem { Label("Map", systemImage: "map") }
            .tag(AppTab.map)

            NavigationStack {
                ConnectionCheckView()
            }
            .tabItem { Label("Connection", systemImage: "antenna.radiowaves.left.and.right") }
            .tag(AppTab.check)

            TerminalHomeView()
                .environmentObject(terminal)
                .environmentObject(terminal.hosts)
                .environmentObject(terminal.keys)
                .tabItem { Label("Terminal", systemImage: "apple.terminal") }
                .tag(AppTab.terminal)
        }
        .sheet(isPresented: $router.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $router.showSetup) {
            SetupView()
        }
    }

    /// lojo://pair links arrive here when the owner scans the gateway's QR code with the Camera app.
    private func openPairingLink(_ url: URL) {
        guard let offer = PairingOffer(code: url.absoluteString) else {
            store.show(Toast(style: .error, message: "That link isn't a valid LOJO pairing code."))
            Haptics.error()
            return
        }
        let wasPresenting = router.showSettings || router.showSetup
        router.showSettings = false
        router.showSetup = false
        Task {
            if wasPresenting { try? await Task.sleep(for: .milliseconds(600)) }
            store.pendingPairing = offer
        }
    }

    private func applyLaunchOptions() {
        guard !appliedLaunch else { return }
        appliedLaunch = true
        let launch = store.launch
        guard let screen = launch.screen else { return }
        onboarded = screen != .onboarding
        switch screen {
        case .onboarding, .home: router.tab = .network
        case .activity: router.tab = .activity
        case .map: router.tab = .map
        case .check: router.tab = .check
        case .terminal: router.tab = .terminal
        case .settings:
            router.tab = .network
            router.showSettings = true
        case .setup:
            router.tab = .network
            router.showSetup = true
        case .detail:
            router.tab = .network
            router.pendingConfirmPin = launch.confirmPin
            Task {
                for _ in 0..<40 where store.devices.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                let wanted = launch.device?.lowercased()
                let match = store.devices.first {
                    guard let wanted else { return $0.camera.enabled && $0.online }
                    return $0.key.lowercased() == wanted || $0.displayName.lowercased() == wanted
                        || $0.name.lowercased() == wanted
                } ?? store.devices.first
                if let match { router.networkPath = [match.key] }
            }
        }
    }
}
