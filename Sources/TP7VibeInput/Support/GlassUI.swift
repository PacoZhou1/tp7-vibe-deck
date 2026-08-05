import SwiftUI

struct LiquidGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func liquidGlassPanel(cornerRadius: CGFloat = 22, shadow: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
                        .stroke(.white.opacity(0.22), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(shadow ? 0.12 : 0), radius: 24, y: 14)
        }
    }

    @ViewBuilder
    func liquidGlassControl(selected: Bool = false, cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .foregroundStyle(selected ? .primary : .secondary)
                .glassEffect(in: shape)
        } else {
            self
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.055), in: shape)
                .overlay {
                    shape
                        .stroke(selected ? Color.accentColor.opacity(0.32) : .white.opacity(0.18), lineWidth: selected ? 1 : 0.8)
                }
        }
    }
}
