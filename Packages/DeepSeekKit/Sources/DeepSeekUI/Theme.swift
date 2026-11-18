import SwiftUI
import DeepSeekCore

public enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case light
    case system
    case dark

    public var label: String {
        switch self {
        case .light: return "纯净白蓝（默认）"
        case .system: return "跟随系统"
        case .dark: return "深邃暗色"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .system: return nil
        case .dark: return .dark
        }
    }
}

/// Official-inspired Clean Royal Blue (#4D6BFE) + Pure Paper White (#FFFFFF) Minimalist Palette.
public enum DeepSeekTheme {
    /// Signature DeepSeek / Modern AI Royal Blue (#4D6BFE)
    public static let brandBlue = Color(red: 0.302, green: 0.420, blue: 0.996)

    public static func brandSoftFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.302, green: 0.420, blue: 0.996).opacity(0.18)
            : Color(red: 0.933, green: 0.949, blue: 1.000) // #EEF2FF
    }

    public static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.059, green: 0.067, blue: 0.090) // #0F1117
            : Color(red: 1.000, green: 1.000, blue: 1.000) // #FFFFFF
    }

    public static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.106, green: 0.118, blue: 0.153) // #1B1E27
            : Color(red: 0.965, green: 0.973, blue: 0.988) // #F6F8FC
    }

    public static func userBubble(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.165, green: 0.220, blue: 0.435)
            : Color(red: 0.933, green: 0.949, blue: 1.000) // Soft ice-blue #EEF2FF
    }

    public static func primaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.965, green: 0.973, blue: 0.988)
            : Color(red: 0.067, green: 0.094, blue: 0.153) // #111827
    }

    public static func secondaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.600, green: 0.635, blue: 0.702)
            : Color(red: 0.420, green: 0.455, blue: 0.522) // #6B7485
    }

    public static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color(red: 0.886, green: 0.910, blue: 0.941) // #E2E8F0
    }

    public static let diffAdded = Color(red: 0.086, green: 0.639, blue: 0.290)
    public static let diffRemoved = Color(red: 0.863, green: 0.149, blue: 0.149)
}

/// Crisp Blue & White Minimalist Emblem (App Store 5.2 trademark-safe original vector geometry in #4D6BFE & White).
public struct MinimalBrandMark: View {
    public var size: CGFloat

    public init(size: CGFloat = 42) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(DeepSeekTheme.brandBlue)
                .frame(width: size, height: size)
                .shadow(color: DeepSeekTheme.brandBlue.opacity(0.22), radius: size * 0.18, y: size * 0.08)

            Canvas { context, canvasSize in
                let c = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.52)
                let r = min(canvasSize.width, canvasSize.height) * 0.27

                // Fluid ocean-arc + spark in crisp pure white
                var mainArc = Path()
                mainArc.addArc(center: c, radius: r, startAngle: .degrees(-35), endAngle: .degrees(205), clockwise: false)
                context.stroke(mainArc, with: .color(.white), style: StrokeStyle(lineWidth: max(2.0, size * 0.075), lineCap: .round))

                var tailCrest = Path()
                tailCrest.move(to: CGPoint(x: c.x - r * 0.92, y: c.y - r * 0.42))
                tailCrest.addQuadCurve(
                    to: CGPoint(x: c.x - r * 0.25, y: c.y - r * 0.95),
                    control: CGPoint(x: c.x - r * 0.82, y: c.y - r * 0.92)
                )
                context.stroke(tailCrest, with: .color(.white.opacity(0.92)), style: StrokeStyle(lineWidth: max(1.6, size * 0.06), lineCap: .round))

                let dot = size * 0.12
                context.fill(
                    Path(ellipseIn: CGRect(x: c.x + r * 0.12 - dot * 0.5, y: c.y - r * 0.18 - dot * 0.5, width: dot, height: dot)),
                    with: .color(.white)
                )
            }
            .frame(width: size, height: size)
        }
    }
}
