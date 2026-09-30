import Foundation

/// QA hooks read from the launch environment (see docs/design.md and scripts/phone-shot.sh).
/// They can only be set by a developer launch over USB, never by a customer.
struct LaunchOptions: Sendable {
    enum Screen: String, Sendable {
        case home, detail, activity, map, check, onboarding, settings, setup
    }

    var demo: Bool?
    var screen: Screen?
    var device: String?
    var simulateOffline: Bool
    var confirmPin: String?
    var appearance: Appearance?
    var lanOverride: String?
    var overlayOverride: String?
    /// Debug builds only: "capture" or "gpio:<pin>:<0|1>" runs that action on the detail screen.
    var autotest: String?

    static let current: LaunchOptions = {
        let env = ProcessInfo.processInfo.environment
        func flag(_ key: String) -> Bool? {
            guard let v = env[key]?.lowercased(), !v.isEmpty else { return nil }
            return ["1", "true", "yes", "on"].contains(v)
        }
        func text(_ key: String) -> String? {
            guard let v = env[key], !v.isEmpty else { return nil }
            return v
        }
        var autotest: String?
        #if DEBUG
        autotest = text("LOJO_AUTOTEST")
        #endif
        return LaunchOptions(
            demo: flag("LOJO_DEMO"),
            screen: text("LOJO_SCREEN").flatMap { Screen(rawValue: $0.lowercased()) },
            device: text("LOJO_DEVICE"),
            simulateOffline: flag("LOJO_SIMULATE_OFFLINE") ?? false,
            confirmPin: text("LOJO_CONFIRM_GPIO"),
            appearance: text("LOJO_APPEARANCE").flatMap { Appearance(rawValue: $0.lowercased()) },
            lanOverride: text("LOJO_LAN"),
            overlayOverride: text("LOJO_OVERLAY"),
            autotest: autotest
        )
    }()
}
