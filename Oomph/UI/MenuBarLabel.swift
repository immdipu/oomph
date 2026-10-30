import AppKit
import SwiftUI

/// The menu bar icon: the slider symbol, knocked out of a filled rounded square when the
/// EQ is on, with a red dot when something needs attention.
struct MenuBarLabel: View {
    let store: EqtuneStore

    var body: some View {
        let on = store.status?.isOn == true
        // eqtune's `last error` sticks around after the engine recovers, so the dot follows
        // whether there is a problem now.
        let alert = store.isFailing || store.blocker != nil
        Image(nsImage: Self.icon(on: on, alert: alert))
            .accessibilityLabel("Oomph, EQ \(on ? "on" : "off")\(alert ? ", needs attention" : "")")
    }

    static func icon(on: Bool, alert: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: on ? 10 : 13, weight: on ? .bold : .medium)
        guard let symbol = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return NSImage() }
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: false) { rect in
            // A template image only needs alpha; the red dot makes it a color image, which
            // then needs the menu bar's own text color (resolved here, at draw time).
            let ink = alert ? NSColor.labelColor : .black
            let glyph = NSRect(x: rect.midX - symbol.size.width / 2, y: rect.midY - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height)
            if on {
                ink.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 0.5), xRadius: 4, yRadius: 4).fill()
                symbol.draw(in: glyph, from: .zero, operation: .destinationOut, fraction: 1)
            } else {
                symbol.draw(in: glyph)
                ink.setFill()
                rect.fill(using: .sourceAtop)
            }
            if alert {
                let dot = NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill(using: .clear)
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = !alert
        return image
    }
}

private extension NSBezierPath {
    /// Fills with a compositing operation (used to punch a gap around the error dot).
    func fill(using operation: NSCompositingOperation) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = operation
        fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
