import AppKit
import SwiftUI

/// A moment's message near the bottom of the screen, like macOS's own overlays, so a global
/// shortcut says what it did while no Oomph window is open.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hiding: Task<Void, Never>?

    static func show(_ text: String, symbol: String) {
        let panel = panel ?? makePanel()
        Self.panel = panel
        let content = NSHostingView(rootView: HUDContent(text: text, symbol: symbol))
        let effect = panel.contentView as! NSVisualEffectView
        effect.subviews.forEach { $0.removeFromSuperview() }
        effect.addSubview(content)
        let size = content.fittingSize
        content.frame = NSRect(origin: .zero, size: size)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 120, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        panel.contentView = effect
        return panel
    }
}

private struct HUDContent: View {
    let text: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40, weight: .medium))
            Text(text).font(.title3.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(minWidth: 180)
    }
}
