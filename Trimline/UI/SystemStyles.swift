import SwiftUI

// Liquid Glass on macOS 26, system materials and capsule buttons on macOS 14–15.
extension View {
    @ViewBuilder
    func capsuleButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    @ViewBuilder
    func capsuleBackground() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        .primary.opacity(MaterialMetrics.edgeOpacity), lineWidth: MaterialMetrics.edgeWidth)
                )
                .shadow(
                    color: .black.opacity(MaterialMetrics.shadowOpacity), radius: MaterialMetrics.shadowRadius,
                    y: MaterialMetrics.shadowOffset)
        }
    }

    /// Lets neighbouring glass controls share one sampling pass and blend as a group.
    @ViewBuilder
    func glassGroup() -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer { self }
        } else {
            self
        }
    }

    func symbolReplaceTransition() -> some View {
        modifier(SymbolReplaceTransition())
    }

    @ViewBuilder
    func dropTargetBackground(cornerRadius: CGFloat, tintOpacity: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(Color.accentColor.opacity(tintOpacity)), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .background(Color.accentColor.opacity(tintOpacity), in: shape)
        }
    }

    /// Decoration in the content layer, so it stays a material tile rather than glass on every system.
    func raisedTileBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.thickMaterial, in: shape)
            .overlay(
                shape.strokeBorder(.primary.opacity(MaterialMetrics.edgeOpacity), lineWidth: MaterialMetrics.edgeWidth)
            )
            .shadow(
                color: .black.opacity(MaterialMetrics.shadowOpacity), radius: MaterialMetrics.shadowRadius,
                y: MaterialMetrics.shadowOffset)
    }
}

private struct SymbolReplaceTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        } else {
            content
        }
    }
}

private enum MaterialMetrics {
    static let edgeOpacity = 0.1
    static let edgeWidth: CGFloat = 0.5
    static let shadowOpacity = 0.08
    static let shadowRadius: CGFloat = 7
    static let shadowOffset: CGFloat = 4
}

enum TrimColors {
    static let frame = Color(nsColor: .systemYellow)
    static let grip = Color(red: 70 / 255, green: 52 / 255, blue: 0)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
}
