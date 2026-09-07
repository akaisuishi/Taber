import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case original
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .dark: "Dark"
        case .light: "Claro"
        }
    }

    var description: String {
        switch self {
        case .original: "Azul e roxo característicos do Taber."
        case .dark: "Preto profundo e contraste discreto."
        case .light: "Branco suave para ambientes claros."
        }
    }

    var symbolName: String {
        switch self {
        case .original: "sparkles"
        case .dark: "moon.stars.fill"
        case .light: "sun.max.fill"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .original, .dark: .dark
        case .light: .light
        }
    }

    var palette: TaberThemePalette {
        switch self {
        case .original:
            TaberThemePalette(
                background: Color(red: 0.055, green: 0.058, blue: 0.072),
                panel: Color(red: 0.075, green: 0.078, blue: 0.095),
                surface: Color.white.opacity(0.055),
                raisedSurface: Color.white.opacity(0.085),
                border: Color.white.opacity(0.13),
                primary: .white,
                secondary: Color.white.opacity(0.66),
                tertiary: Color.white.opacity(0.42),
                accent: Color(red: 0.20, green: 0.72, blue: 0.98),
                accentSecondary: Color(red: 0.49, green: 0.32, blue: 0.94),
                thumbnailBackground: Color.black.opacity(0.34)
            )

        case .dark:
            TaberThemePalette(
                background: Color(red: 0.012, green: 0.012, blue: 0.014),
                panel: Color(red: 0.022, green: 0.022, blue: 0.026),
                surface: Color.white.opacity(0.045),
                raisedSurface: Color.white.opacity(0.075),
                border: Color.white.opacity(0.11),
                primary: .white,
                secondary: Color.white.opacity(0.62),
                tertiary: Color.white.opacity(0.38),
                accent: Color(red: 0.36, green: 0.64, blue: 1.0),
                accentSecondary: Color(red: 0.42, green: 0.45, blue: 0.58),
                thumbnailBackground: Color.black.opacity(0.72)
            )

        case .light:
            TaberThemePalette(
                background: Color(red: 0.955, green: 0.965, blue: 0.985),
                panel: Color(red: 0.985, green: 0.988, blue: 1.0),
                surface: Color.black.opacity(0.045),
                raisedSurface: Color.white.opacity(0.92),
                border: Color.black.opacity(0.11),
                primary: Color(red: 0.075, green: 0.085, blue: 0.12),
                secondary: Color(red: 0.26, green: 0.29, blue: 0.37),
                tertiary: Color(red: 0.43, green: 0.46, blue: 0.53),
                accent: Color(red: 0.08, green: 0.42, blue: 0.94),
                accentSecondary: Color(red: 0.45, green: 0.25, blue: 0.88),
                thumbnailBackground: Color(red: 0.88, green: 0.90, blue: 0.94)
            )
        }
    }
}

struct TaberThemePalette {
    let background: Color
    let panel: Color
    let surface: Color
    let raisedSurface: Color
    let border: Color
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let accent: Color
    let accentSecondary: Color
    let thumbnailBackground: Color

    var selection: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.14), accent.opacity(0.10), accentSecondary.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct TaberThemePaletteKey: EnvironmentKey {
    static let defaultValue = AppTheme.original.palette
}

extension EnvironmentValues {
    var taberThemePalette: TaberThemePalette {
        get { self[TaberThemePaletteKey.self] }
        set { self[TaberThemePaletteKey.self] = newValue }
    }
}

enum TaberDesign {
    static let radius: CGFloat = 12
    static let transitionDuration = 0.15
}

struct TaberSurfaceBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let color: Color
    var material: NSVisualEffectView.Material = .popover
    var body: some View {
        ZStack {
            if !reduceTransparency { TaberMaterial(material: material) }
            color.opacity(reduceTransparency ? 1 : 0.94)
        }
    }
}

private struct TaberMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView { NSVisualEffectView() }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
    }
}

struct TaberChoiceSurface: View {
    @Environment(\.taberThemePalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast
    var selected: Bool
    var radius: CGFloat = TaberDesign.radius
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(selected ? AnyShapeStyle(palette.selection) : AnyShapeStyle(palette.surface.opacity(0.35)))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(selected ? palette.accent : (contrast == .increased ? palette.secondary : palette.border.opacity(0.65)), lineWidth: selected ? 1.5 : 1)
            }
    }
}

struct KeycapStyle: ViewModifier {
    @Environment(\.taberThemePalette) private var palette
    func body(content: Content) -> some View {
        content.font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 5))
    }
}

extension SwitcherStyle {
    var shortTitle: String {
        switch self { case .preview: "Miniaturas"; case .list: "Lista"; case .icons: "Ícones"; case .flow: "Fluxo" }
    }
}
