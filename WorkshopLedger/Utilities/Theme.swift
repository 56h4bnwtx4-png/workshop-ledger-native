import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.933, green: 0.945, blue: 0.957)
    static let surface = Color.white
    static let surfaceSoft = Color(red: 0.973, green: 0.976, blue: 0.984)
    static let line = Color(red: 0.89, green: 0.91, blue: 0.93)
    static let text = Color(red: 0.09, green: 0.13, blue: 0.18)
    static let textMuted = Color(red: 0.41, green: 0.45, blue: 0.52)
    static let textFaint = Color(red: 0.60, green: 0.64, blue: 0.70)
    static let accent = Color(red: 0.91, green: 0.46, blue: 0.14)
    static let accentDark = Color(red: 0.79, green: 0.36, blue: 0.08)
    static let accentSoft = Color(red: 1.0, green: 0.945, blue: 0.905)
    static let navy = Color(red: 0.09, green: 0.13, blue: 0.18)
    static let danger = Color(red: 0.77, green: 0.24, blue: 0.24)
    static let dangerSoft = Color(red: 1.0, green: 0.949, blue: 0.949)
    static let success = Color(red: 0.18, green: 0.56, blue: 0.35)
}

struct Panel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
            )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(height: 42)
            .background(configuration.isPressed ? AppTheme.accentDark : AppTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(AppTheme.text)
            .padding(.horizontal, 15)
            .frame(height: 40)
            .background(configuration.isPressed ? AppTheme.surfaceSoft : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
            )
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(AppTheme.textFaint)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppTheme.text)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(AppTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

struct WorkshopShell<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.957, green: 0.965, blue: 0.973),
                    AppTheme.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.surface.ignoresSafeArea())
        }
    }
}

struct WorkshopTopBar<Trailing: View>: View {
    let brandTitle: String
    let brandSubtitle: String
    let brandIcon: String
    let leadingIcon: String
    let backAction: (() -> Void)?
    let trailing: Trailing

    init(
        brandTitle: String,
        brandSubtitle: String,
        brandIcon: String,
        leadingIcon: String = "chevron.left",
        backAction: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.brandTitle = brandTitle
        self.brandSubtitle = brandSubtitle
        self.brandIcon = brandIcon
        self.leadingIcon = leadingIcon
        self.backAction = backAction
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack {
                if let backAction {
                    TopIconButton(icon: leadingIcon, action: backAction)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Image("BrandAvatar")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: AppTheme.accent.opacity(0.28), radius: 9, x: 0, y: 7)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(brandTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text(brandSubtitle.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.60, green: 0.64, blue: 0.71))
                }
            }
            .fixedSize()

            HStack {
                Spacer(minLength: 0)
                trailing
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 28)
        .frame(height: 76)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.035), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .background(AppTheme.navy)
        )
        .overlay(Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1), alignment: .bottom)
    }
}

struct TopIconButton: View {
    let icon: String
    let action: () -> Void
    var emphasized = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(emphasized ? AppTheme.navy : Color(red: 0.86, green: 0.88, blue: 0.91))
                .frame(width: 44, height: 44)
                .background(emphasized ? Color.white : Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(emphasized ? Color.white : Color.white.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct LocalModeBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0.33, green: 0.71, blue: 0.55))
                .frame(width: 7, height: 7)
                .shadow(color: Color(red: 0.33, green: 0.71, blue: 0.55).opacity(0.15), radius: 3)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 0.80, green: 0.83, blue: 0.87))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.white.opacity(0.05))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 1))
    }
}

struct PageEyebrow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(AppTheme.accent)
                .frame(width: 18, height: 2)
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppTheme.accentDark)
        }
    }
}

struct PageHeading<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let note: String
    let trailing: Trailing

    init(eyebrow: String, title: String, note: String, @ViewBuilder trailing: () -> Trailing) {
        self.eyebrow = eyebrow
        self.title = title
        self.note = note
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 28) {
            VStack(alignment: .leading, spacing: 0) {
                PageEyebrow(text: eyebrow)
                    .padding(.bottom, 9)
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.text)
                Text(note)
                    .font(.system(size: 14))
                    .foregroundColor(AppTheme.textMuted)
                    .lineSpacing(3)
                    .padding(.top, 9)
            }
            Spacer(minLength: 20)
            trailing
        }
        .padding(.bottom, 24)
    }
}

struct PageScopeBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(AppTheme.textFaint)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(AppTheme.text)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 54)
        .background(AppTheme.surfaceSoft)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        )
    }
}
struct StatusTag: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(background)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(foreground.opacity(0.18), lineWidth: 1))
    }
}
