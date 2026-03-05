import AppKit

extension NSImage {
    /// Returns a new image scaled to the given size using the modern drawing handler API.
    /// Retina-correct and appearance-aware (re-renders on resolution/dark mode changes).
    func scaled(to size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            return true
        }
    }
}
