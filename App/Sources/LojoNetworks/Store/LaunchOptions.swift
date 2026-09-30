import Foundation

/// QA hooks read from the launch environment (see docs/design.md and scripts/phone-shot.sh).
/// They can only be set by a developer launch over USB, never by a customer.
struct LaunchOptions: Sendable {
    enum Screen: String, Sendable {
        case home, detail, activity, map, check, onboarding, settings, setup, terminal
    }

    var demo: Bool?
    var screen: Screen?
    var device: String?
    var simulateOffline: Bool
    var confirmPin: String?
    var appearance: Appearance?
    var lanOverride: String?
    var overlayOverride: String?
    /// "diagnostics" scrolls the Connection check to its diagnostics card once the check finishes.
    var scroll: String?
    /// Debug builds only: "capture" or "gpio:<pin>:<0|1>" runs that action on the detail screen.
    var autotest: String?
    /// A lojo://pair code to show the pairing sheet for, as if scanned with the Camera app.
    var pairingCode: String?
    /// Debug builds only: pair with `pairingCode` without waiting for the Pair tap.
    var confirmPairing = false
    /// Remove the pinned site CA at launch.
    var unpair = false

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
        var confirmPairing = false
        #if DEBUG
        autotest = text("LOJO_AUTOTEST")
        confirmPairing = flag("LOJO_PAIR_CONFIRM") ?? false
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
            scroll: text("LOJO_SCROLL")?.lowercased(),
            autotest: autotest,
            pairingCode: text("LOJO_PAIR"),
            confirmPairing: confirmPairing,
            unpair: flag("LOJO_UNPAIR") ?? false
        )
    }()
}
