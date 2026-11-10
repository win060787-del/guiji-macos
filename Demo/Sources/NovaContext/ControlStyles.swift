import SwiftUI

/// Shared pointer target for compact desktop actions. Native buttons retain keyboard activation.
struct WorkspaceIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration)
    }
    private struct IconBody: View {
    @Environment(\.locale) private var locale
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 18, weight: .medium))
                .frame(width: 36, height: 36)
                .background(
                    configuration.isPressed ? Palette.accent.opacity(0.18) : hovering ? Palette.accent.opacity(0.10) : Palette.surface,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(contrast == .increased ? Color.secondary : Palette.line))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// Allow dialogs to fit smaller Mac displays without placing their actions behind the Dock.
enum WorkspaceDialog {
    static var width: CGFloat { min(940, (NSScreen.main?.visibleFrame.width ?? 1024) - 80) }
    static var height: CGFloat { min(680, (NSScreen.main?.visibleFrame.height ?? 768) - 100) }
}
