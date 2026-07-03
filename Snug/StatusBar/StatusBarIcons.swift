import AppKit

/// Draws the template images for Snug's two status items. Pure drawing —
/// no status-bar state. All images are template images so they adapt to
/// menu bar appearance automatically.
enum StatusBarIcon {

    private static let circleR: CGFloat = 6
    private static let circleCY: CGFloat = 9
    private static let lineWidth: CGFloat = 1.5

    /// Left half-circle  (
    static func separator() -> NSImage {
        let image = NSImage(size: NSSize(width: 9, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.appendArc(withCenter: NSPoint(x: 7, y: circleCY),
                           radius: circleR,
                           startAngle: 90, endAngle: 270)
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Full outlined circle  ○
    static func expanded() -> NSImage {
        let d = circleR * 2
        let w = d + 4
        let cx = w / 2
        let image = NSImage(size: NSSize(width: w, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let path = NSBezierPath(ovalIn: NSRect(x: cx - circleR, y: circleCY - circleR,
                                                    width: d, height: d))
            path.lineWidth = lineWidth
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Toggle icon when collapsed: left half-circle + filled circle.
    /// The arc radius matches the filled circle so they look like a pair.
    ///   count == 0 → ( + small filled solid circle
    ///   count  > 0 → ( + filled circle with count cut out
    static func collapsed(count: Int) -> NSImage {
        let pad: CGFloat = 1   // padding on each side
        let gap: CGFloat = 1   // space between arc right edge and filled circle left edge
        let h: CGFloat = 18
        let cy = h / 2

        if count <= 0 {
            let r = circleR                          // 6 — both arc and fill
            let arcCX = pad + r                      // arc center; rightmost point of arc
            let filledCX = arcCX + gap + r           // filled circle center
            let w = filledCX + r + pad               // total image width

            let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
                // Left half-circle ( — matching radius
                NSColor.black.setStroke()
                let arc = NSBezierPath()
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                arc.appendArc(withCenter: NSPoint(x: arcCX, y: cy),
                              radius: r, startAngle: 90, endAngle: 270)
                arc.stroke()

                // Filled circle
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: filledCX - r, y: cy - r,
                                            width: r * 2, height: r * 2)).fill()
                return true
            }
            image.isTemplate = true
            return image
        }

        let r: CGFloat = 8                          // filled circle radius (original size)
        let arcHR: CGFloat = 3                       // horizontal radius (narrow)
        let arcVR = r - 2                            // vertical radius matches filled circle
        let arcCX = pad + arcHR                      // arc center X
        let filledCX = arcCX + gap + r               // filled circle center
        let w = filledCX + r + pad                   // total image width

        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            // Elliptical arc ( — tall & narrow, peeks from behind the circle
            NSColor.black.setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: .zero, radius: 1.0,
                          startAngle: 90, endAngle: 270)
            var xform = AffineTransform.identity
            xform.translate(x: arcCX, y: cy)
            xform.scale(x: arcHR, y: arcVR)
            arc.transform(using: xform)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            arc.stroke()

            // Filled circle with count
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: filledCX - r, y: cy - r,
                                        width: r * 2, height: r * 2)).fill()

            let text = count > 9 ? "9+" : "\(count)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let ts = text.size(withAttributes: attrs)

            NSGraphicsContext.current?.compositingOperation = .clear
            text.draw(at: NSPoint(x: filledCX - ts.width / 2,
                                  y: cy - ts.height / 2),
                      withAttributes: attrs)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
    }
}
