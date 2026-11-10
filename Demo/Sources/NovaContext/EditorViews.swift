import SwiftUI
import AppKit

struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    let accessibilityName: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isRichText = false; editor.importsGraphics = false
        editor.allowsUndo = true; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textContainerInset = NSSize(width: 24, height: 24)
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(accessibilityName)
        editor.string = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text { editor.string = text; editor.undoManager?.removeAllActions() }
        editor.isEditable = editable
        editor.backgroundColor = .textBackgroundColor; editor.textColor = .textColor
        editor.insertionPointColor = .textColor
        scroll.backgroundColor = .textBackgroundColor
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceEditor
        init(_ parent: SourceEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

struct FrostedPanel: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency { Palette.paper } else { VisualEffect().overlay(Palette.paper.opacity(0.42)) }
    }
    private struct VisualEffect: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .sidebar; view.blendingMode = .behindWindow; view.state = .followsWindowActiveState
            return view
        }
        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }
}

struct DocumentWindow: NSViewRepresentable {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var vault: CredentialVaultModel
    @ObservedObject var services: LocalServicesModel
    func makeCoordinator() -> Coordinator { Coordinator(model, vault: vault, services: services) }
    func makeNSView(context: Context) -> NSView { WindowHook(coordinator: context.coordinator) }
    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { model.window = window }
        view.window?.isDocumentEdited = model.isDirty
        view.window?.representedURL = model.documentURL
    }
    private final class WindowHook: NSView {
        let coordinator: Coordinator
        init(coordinator: Coordinator) { self.coordinator = coordinator; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.delegate = coordinator
            coordinator.model.window = window
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: WorkspaceModel
        let vault: CredentialVaultModel
        let services: LocalServicesModel
        init(_ model: WorkspaceModel, vault: CredentialVaultModel, services: LocalServicesModel) {
            self.model = model; self.vault = vault; self.services = services
        }
        func windowWillEnterFullScreen(_ notification: Notification) { model.isFullScreen = true }
        func windowDidExitFullScreen(_ notification: Notification) { model.isFullScreen = false }
        func windowDidFailToEnterFullScreen(_ window: NSWindow) { model.isFullScreen = false }
        func windowDidFailToExitFullScreen(_ window: NSWindow) { model.isFullScreen = true }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if model.saving || vault.busy || services.busy || !vault.confirmDiscardEditor() { return false }
            guard model.isDirty else { return true }
            model.performAfterEdits { sender.close() }
            return false
        }
    }
}
