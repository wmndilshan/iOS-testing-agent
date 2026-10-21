import SwiftUI
import AgentCore
import AgentPresentation
import AgentComposition

/// The tokens every view draws from: spacing, corner radii, type and tone colours. Colours are always semantic (system colours), so light and
/// dark both work. A view that needs a number that is not here should add a token rather than write the number.
enum DS {
    enum Space {
        static let hair: CGFloat = 3
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 14
    }

    enum Typography {
        static let monoCaption = Font.system(.caption, design: .monospaced)
        static let monoCallout = Font.system(.callout, design: .monospaced)
        /// The large symbol of an empty state.
        static let heroSymbol = Font.system(size: 34, weight: .light)
        /// A status icon in a list row.
        static let rowIcon = Font.system(size: 18)
    }

    /// One restrained accent (a slate blue) and muted status colours: colour carries meaning (pass, fail, attention) and nothing else.
    static let accent = Color(red: 0.36, green: 0.49, blue: 0.68)

    enum Palette {
        static let success = Color(red: 0.34, green: 0.62, blue: 0.47)
        static let warning = Color(red: 0.80, green: 0.60, blue: 0.30)
        static let failure = Color(red: 0.82, green: 0.38, blue: 0.36)
    }

    /// Aspect ratio of the phone preview (iPhone 15/16 class: 1179 x 2556).
    static let phoneAspect: CGFloat = 1179.0 / 2556.0
}

extension StatusTone {
    var tint: Color {
        switch self {
        case .neutral: return .secondary
        case .active: return DS.accent
        case .success: return DS.Palette.success
        case .warning: return DS.Palette.warning
        case .failure: return DS.Palette.failure
        }
    }
}

extension View {
    /// The one rounded surface of the app: cards, banners, code blocks, the composer. Untinted it is a control-background fill with a hairline
    /// separator border; with a `tint` it becomes a pale wash of that colour with a border to match.
    /// With `wash: false` only the border takes the tint and the fill stays neutral (a focused field, a highlighted card).
    func dsSurface(radius: CGFloat = DS.Radius.m, tint: Color? = nil, borderOpacity: Double = 0.45, wash: Bool = true, selected: Bool = false) -> some View {
        modifier(DSSurface(radius: radius, tint: tint, borderOpacity: borderOpacity, wash: wash, selected: selected))
    }
}

private struct DSSurface: ViewModifier {
    let radius: CGFloat
    let tint: Color?
    let borderOpacity: Double
    let wash: Bool
    let selected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .background((wash ? tint.map { $0.opacity(0.05) } : nil) ?? Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(selected ? DS.accent : (tint.map { $0.opacity(min(borderOpacity, 0.3)) } ?? Color(nsColor: .separatorColor)), lineWidth: selected ? 2 : 1))
    }
}
