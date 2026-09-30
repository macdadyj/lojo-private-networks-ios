import SwiftUI
import UIKit

enum LojoTheme {
    static let accent = Color(red: 0.06, green: 0.55, blue: 0.58)
    static let accentDeep = Color(red: 0.15, green: 0.18, blue: 0.47)
    static let online = Color(red: 0.16, green: 0.72, blue: 0.45)
    static let offline = Color.secondary
    static let warning = Color(red: 0.95, green: 0.62, blue: 0.10)
    static let danger = Color(red: 0.90, green: 0.27, blue: 0.25)
    /// accentDeep is too dark to read on black; controls use this adaptive indigo instead.
    static let control = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.56, green: 0.61, blue: 0.96, alpha: 1)
            : UIColor(red: 0.15, green: 0.18, blue: 0.47, alpha: 1)
    })

    static let brandGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cornerRadius: CGFloat = 18
}

enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match iPhone"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LojoTheme.cornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LojoTheme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

enum DeviceStatusStyle {
    case online, offline, unknown

    var color: Color {
        switch self {
        case .online: return LojoTheme.online
        case .offline: return .secondary
        case .unknown: return LojoTheme.warning
        }
    }

    var label: String {
        switch self {
        case .online: return "Online"
        case .offline: return "Offline"
        case .unknown: return "Unknown"
        }
    }
}

/// Filled dot for online, hollow ring for offline, so status never relies on color alone.
struct StatusDot: View {
    let style: DeviceStatusStyle
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            switch style {
            case .online:
                Circle().fill(style.color)
                Circle().stroke(style.color.opacity(0.35), lineWidth: 4).scaleEffect(1.5)
            case .offline:
                Circle().strokeBorder(style.color, lineWidth: 2)
            case .unknown:
                Circle().fill(style.color).mask(
                    Rectangle().frame(width: size, height: size / 2).offset(y: size / 4)
                )
                Circle().strokeBorder(style.color, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

struct Chip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

struct DeviceIcon: View {
    let kind: DeviceKind
    let online: Bool
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(online ? AnyShapeStyle(LojoTheme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.25)))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: kind.systemImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(online ? Color.white : Color.secondary)
            )
            .accessibilityHidden(true)
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(.caption2.weight(.heavy))
            .tracking(1.2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(Capsule().fill(LojoTheme.warning))
            .accessibilityLabel("Demo mode. Sample data, no real devices.")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = LojoTheme.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isEnabled ? tint : Color.secondary.opacity(0.4))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(LojoTheme.accent)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LojoTheme.accent.opacity(0.12))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

@MainActor
enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func rigid() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

struct Toast: Identifiable, Equatable {
    enum Style { case success, info, warning, error }

    let id = UUID()
    let style: Style
    let message: String

    var systemImage: String {
        switch style {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch style {
        case .success: return LojoTheme.online
        case .info: return LojoTheme.accent
        case .warning: return LojoTheme.warning
        case .error: return LojoTheme.danger
        }
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(toast.tint)
                .font(.title3)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

enum RelativeTime {
    static func text(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let delta = now.timeIntervalSince(date)
        if delta < 45 { return "just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func full(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
