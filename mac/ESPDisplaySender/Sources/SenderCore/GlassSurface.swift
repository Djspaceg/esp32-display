import SwiftUI

/// Liquid Glass, or a solid surface when the user has asked for one.
///
/// Every glass surface in the app goes through here rather than calling
/// `glassEffect` directly, because Reduce Transparency has to be honoured in one
/// place or it will be honoured in none. Liquid Glass has well documented
/// legibility costs and these windows are mostly small telemetry text, so the
/// opaque fallback is a real design state rather than a grudging concession.
struct GlassCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(shape.fill(.background.secondary))
                .overlay(shape.strokeBorder(.separator, lineWidth: 1))
        } else {
            content
                .glassEffect(
                    .regular.tint(tint).interactive(interactive), in: shape)
        }
    }
}

extension View {
    /// A glass surface with the app's standard corner radius.
    ///
    /// - Parameters:
    ///   - tint: colours the glass. Reserved for surfaces that mean something -
    ///     a warning, a fault - so the colour keeps its meaning.
    ///   - interactive: let the material respond to the pointer. Only for
    ///     surfaces the user can actually act on.
    func glassCard(
        cornerRadius: CGFloat = 14, tint: Color? = nil, interactive: Bool = false
    ) -> some View {
        modifier(GlassCard(
            cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}
