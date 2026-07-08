import SwiftUI

// MARK: - NotCode design system
//
// The shared visual language for the app's windows. Settings uses it today;
// the upcoming Status panel and onboarding wizard should build their layouts
// from these same pieces so every surface feels like one app.
// Everything here is macOS 13 compatible.

enum DS {
    /// Spacing scale, in points. Prefer these over ad-hoc values.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 10
        static let control: CGFloat = 6
    }

    enum Size {
        /// Tinted square icon in sidebar rows.
        static let sidebarIcon: CGFloat = 22
        /// Tinted square icon in a pane header.
        static let paneIcon: CGFloat = 36
        /// Default width for trailing pickers in a `SettingsRow`.
        static let controlWidth: CGFloat = 190
        /// Default width for trailing text fields in a `SettingsRow`.
        static let fieldWidth: CGFloat = 280
    }
}

// MARK: - Caption style

extension View {
    /// The standard style for helper text under a control.
    func dsCaption() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Tinted icon

/// The System Settings style icon: an SF Symbol on a tinted rounded square.
/// Used in the sidebar and in pane headers.
struct TintedIcon: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = DS.Size.sidebarIcon

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.72)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white))
            .shadow(color: tint.opacity(0.3), radius: 1, y: 0.5)
    }
}

// MARK: - Section header

/// Headline for a group of controls, optionally with a tinted SF Symbol.
struct SectionHeader: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Text(title)
                .font(.headline)
        }
    }
}

// MARK: - Card

/// Rounded material container that groups related controls. Pass a title to
/// get a built-in `SectionHeader`.
struct SettingsCard<Content: View>: View {
    private let title: String?
    private let systemImage: String?
    private let content: Content

    init(_ title: String? = nil,
         systemImage: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            if let title {
                SectionHeader(title, systemImage: systemImage)
            }
            content
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1))
    }
}

// MARK: - Row

/// One setting inside a card: title plus optional caption on the left, the
/// control on the right. Give the control a `.labelsHidden()` label matching
/// the title so accessibility stays intact.
struct SettingsRow<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    init(_ title: String,
         subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).dsCaption()
                }
            }
            Spacer(minLength: DS.Spacing.m)
            trailing
        }
    }
}

// MARK: - Pane

/// A scrollable detail pane with a standard header: tinted icon, title,
/// subtitle, then the content stacked with consistent spacing.
struct SettingsPane<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let tint: Color
    private let content: Content

    init(title: String,
         subtitle: String? = nil,
         systemImage: String,
         tint: Color,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                header
                content
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.m) {
            TintedIcon(systemImage: systemImage, tint: tint, size: DS.Size.paneIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, DS.Spacing.xs)
    }
}

// MARK: - Step dots

/// Progress indicator for a stepped flow (the onboarding wizard): one dot per
/// step, the current one stretched into a tinted capsule.
struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current
                          ? AnyShapeStyle(Color.accentColor)
                          : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: current)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Beta badge

/// Small orange capsule marking an experimental feature.
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.orange.opacity(0.2)))
            .foregroundStyle(.orange)
    }
}
