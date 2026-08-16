import SwiftUI

// MARK: - Hex Color Helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r: Double
        let g: Double
        let b: Double
        if hex.count == 3 {
            r = Double((int >> 8) * 17) / 255
            g = Double((int >> 4 & 0xF) * 17) / 255
            b = Double((int & 0xF) * 17) / 255
        } else if hex.count == 6 {
            r = Double(int >> 16) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        } else {
            r = 0; g = 0; b = 0
        }
        self.init(.sRGB, red: r, green: g, blue: b)
    }
}

// MARK: - UIColor Helpers

#if os(macOS)
private func adaptiveUIColor(dark: UInt32, light: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? uiColorFromHex(dark) : uiColorFromHex(light)
    }
}
#else
private func adaptiveUIColor(dark: UInt32, light: UInt32) -> UIColor {
    UIColor { t in
        t.userInterfaceStyle == .dark ? uiColorFromHex(dark) : uiColorFromHex(light)
    }
}
#endif

private func uiColorFromHex(_ hex: UInt32) -> UIColor {
    UIColor(
        red:   CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8)  & 0xFF) / 255,
        blue:  CGFloat(hex         & 0xFF) / 255,
        alpha: 1
    )
}

// MARK: - AppTheme

enum AppTheme {

    // MARK: Colors — Nemoris palette
    enum Colors {
        // Black graphite (dark) / Soft ivory (light)
        static let background       = Color(uiColor: adaptiveUIColor(dark: 0x111315, light: 0xF3F0EA))
        // Surface with a slight forest tint in dark mode
        static let surface          = Color(uiColor: adaptiveUIColor(dark: 0x191D1B, light: 0xFFFFFF))
        static let surfaceSecondary = Color(uiColor: adaptiveUIColor(dark: 0x222826, light: 0xE8E4DC))

        // Adaptive forest green: deep on ivory, medium on graphite
        static let accent           = Color(uiColor: adaptiveUIColor(dark: 0x52B896, light: 0x1D3A32))
        // Discreet copper — fixed across both modes
        static let accentSecondary  = Color(hex: "B07A4F")
        // Natural green for income / positive values
        static let success          = Color(hex: "3DAA82")
        // Warm amber for alerts
        static let warning          = Color(hex: "C49A5A")
        // Soft terracotta for expenses / negative values
        static let danger           = Color(hex: "C25A46")

        // Warm ivory (dark) / Graphite (light)
        static let textPrimary   = Color(uiColor: adaptiveUIColor(dark: 0xF0EDE6, light: 0x111315))
        // Adaptive stone gray — readable in both modes (≥ WCAG AA)
        static let textSecondary = Color(uiColor: adaptiveUIColor(dark: 0xA8AFAC, light: 0x4F5654))

        static let accentGradient = LinearGradient(
            colors: [Color(hex: "52B896"), Color(hex: "1D5C47")],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        static let successGradient = LinearGradient(
            colors: [Color(hex: "3DAA82"), Color(hex: "1D7A5A")],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        static let dangerGradient = LinearGradient(
            colors: [Color(hex: "C25A46"), Color(hex: "9B3D2C")],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // MARK: Typography — SF Pro Display, understated and refined
    enum Typography {
        static let displayLarge  = Font.system(size: 34, weight: .bold,     design: .default)
        static let displayMedium = Font.system(size: 28, weight: .bold,     design: .default)
        static let displaySmall  = Font.system(size: 22, weight: .semibold, design: .default)
        static let titleLarge    = Font.system(size: 20, weight: .semibold, design: .default)
        static let titleMedium   = Font.system(size: 17, weight: .semibold, design: .default)
        static let titleSmall    = Font.system(size: 15, weight: .medium,   design: .default)
        static let bodyLarge     = Font.system(size: 17, weight: .regular,  design: .default)
        static let bodyMedium    = Font.system(size: 15, weight: .regular,  design: .default)
        static let bodySmall     = Font.system(size: 13, weight: .regular,  design: .default)
        static let labelLarge    = Font.system(size: 13, weight: .medium,   design: .default)
        static let labelMedium   = Font.system(size: 11, weight: .medium,   design: .default)
        static let labelSmall    = Font.system(size: 10, weight: .semibold, design: .default)
        // Financial figures in SF Pro — legible and understated
        static let moneyLarge    = Font.system(size: 36, weight: .semibold, design: .default)
        static let moneyMedium   = Font.system(size: 24, weight: .semibold, design: .default)
        static let moneySmall    = Font.system(size: 17, weight: .medium,   design: .default)
    }

    // MARK: Spacing
    enum Spacing {
        static let xs:   CGFloat = 4
        static let sm:   CGFloat = 8
        static let md:   CGFloat = 12
        static let lg:   CGFloat = 16
        static let xl:   CGFloat = 20
        static let xxl:  CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: Radius
    enum Radius {
        static let sm:   CGFloat = 8
        static let md:   CGFloat = 12
        static let lg:   CGFloat = 16
        static let xl:   CGFloat = 20
        static let xxl:  CGFloat = 24
        static let full: CGFloat = 999
    }

    // MARK: Shadows
    struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
    enum Shadows {
        static let soft   = AppTheme.ShadowStyle(color: .black.opacity(0.14), radius: 10, x: 0, y: 3)
        static let medium = AppTheme.ShadowStyle(color: .black.opacity(0.22), radius: 18, x: 0, y: 6)
        static let strong = AppTheme.ShadowStyle(color: .black.opacity(0.30), radius: 28, x: 0, y: 10)
        static let accent = AppTheme.ShadowStyle(color: Color(hex: "1D3A32").opacity(0.25), radius: 18, x: 0, y: 6)
    }

    // MARK: Animations
    enum Animations {
        static let spring        = Animation.spring(response: 0.4, dampingFraction: 0.8)
        static let springSnappy  = Animation.spring(response: 0.3, dampingFraction: 0.75)
        static let springBouncy  = Animation.spring(response: 0.5, dampingFraction: 0.65)
        static let easeOut       = Animation.easeOut(duration: 0.25)
        static let easeInOut     = Animation.easeInOut(duration: 0.3)
    }
}

// MARK: - View Extensions

extension View {
    func appCardStyle(padding: CGFloat = AppTheme.Spacing.lg) -> some View {
        let s = AppTheme.Shadows.soft
        return self
            .padding(padding)
            .background(AppTheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }

    func appSurface(cornerRadius: CGFloat = AppTheme.Radius.md) -> some View {
        self
            .background(AppTheme.Colors.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    func softShadow() -> some View {
        let s = AppTheme.Shadows.soft
        return shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}
