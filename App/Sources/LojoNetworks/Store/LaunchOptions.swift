import Foundation

/// QA hooks read from the launch environment (see docs/design.md and scripts/phone-shot.sh).
struct LaunchOptions: Sendable {
    enum Screen: String, Sendable {
        case home, detail, activity, map, check, onboarding, settings
    }

    var demo: Bool?
    var screen: Screen?
    var device: String?
    var simulateOffline: Bool
    var confirmPin: String?
    var appearance: Appearance?

    static let current: LaunchOptions = {
        let env = ProcessInfo.processInfo.environment
        func flag(_ key: String) -> Bool? {
            guard let v = env[key]?.lowercased(), !v.isEmpty else { return nil }
            return ["1", "true", "yes", "on"].contains(v)
        }
        return LaunchOptions(
            demo: flag("LOJO_DEMO"),
            screen: env["LOJO_SCREEN"].flatMap { Screen(rawValue: $0.lowercased()) },
            device: env["LOJO_DEVICE"].flatMap { $0.isEmpty ? nil : $0 },
            simulateOffline: flag("LOJO_SIMULATE_OFFLINE") ?? false,
            confirmPin: env["LOJO_CONFIRM_GPIO"].flatMap { $0.isEmpty ? nil : $0 },
            appearance: env["LOJO_APPEARANCE"].flatMap { Appearance(rawValue: $0.lowercased()) }
        )
    }()
}
