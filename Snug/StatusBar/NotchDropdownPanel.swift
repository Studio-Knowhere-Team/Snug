import AppKit
import QuartzCore

@MainActor
final class NotchDropdownPanel: NSObject {

    enum PanelState {
        case hidden
        case showing
        case visible
        case hiding
    }

    var isVisible: Bool {
        panelState == .visible || panelState == .showing
    }

    var panelFrame: CGRect {
        panel.frame
    }

    var onItemSelected: ((HiddenItemInfo) -> Void)?

    private let panel: PanelWindow
    private let visualEffectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let verticalStackView = NSStackView()

    private var panelState: PanelState = .hidden
    private var targetFrame: CGRect = .zero
    private var animationToken = UUID()

    private let contentInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    private let cellSize = NSSize(width: 32, height: 32)
    private let iconSize = NSSize(width: 24, height: 24)
    private let gridSpacing: CGFloat = 8
    private let maxVisibleRows = 3
    private let maxScrollHeight: CGFloat = 160
    private let animationDuration: CFTimeInterval = 0.18
    private let cornerRadius: CGFloat = 12

    override init() {
        panel = PanelWindow(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()
        setupPanel()
        setupContentView()
    }

    func show(items: [HiddenItemInfo], below notchRect: CGRect) {
        rebuildGrid(items: items, notchRect: notchRect)
        targetFrame = frame(forContentSize: contentSize(), below: notchRect)

        let token = prepareForAnimation()
        let startingScale = currentScale(from: visualEffectView.layer?.presentation()) ?? currentScale(from: visualEffectView.layer) ?? 0.96
        let startingOpacity = currentOpacity(from: visualEffectView.layer?.presentation()) ?? currentOpacity(from: visualEffectView.layer) ?? 0

        panel.setContentSize(targetFrame.size)
        panel.setFrame(targetFrame, display: false)
        panel.orderFront(nil)
        panel.alphaValue = 1

        animate(
            state: .showing,
            fromOpacity: startingOpacity,
            toOpacity: 1,
            fromScale: startingScale,
            toScale: 1
        ) { [weak self] in
            guard let self, self.animationToken == token else { return }
            self.panelState = .visible
        }
    }

    func hide(animated: Bool) {
        guard panelState != .hidden else { return }

        if !animated {
            completeHide()
            return
        }

        let token = prepareForAnimation()
        let startingScale = currentScale(from: visualEffectView.layer?.presentation()) ?? currentScale(from: visualEffectView.layer) ?? 1
        let startingOpacity = currentOpacity(from: visualEffectView.layer?.presentation()) ?? currentOpacity(from: visualEffectView.layer) ?? 1

        animate(
            state: .hiding,
            fromOpacity: startingOpacity,
            toOpacity: 0,
            fromScale: startingScale,
            toScale: 0.96
        ) { [weak self] in
            guard let self, self.animationToken == token else { return }
            self.completeHide()
        }
    }

    private func setupPanel() {
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
    }

    private func setupContentView() {
        visualEffectView.material = .menu
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.layer?.opacity = 0
        visualEffectView.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]

        verticalStackView.orientation = .vertical
        verticalStackView.alignment = .leading
        verticalStackView.distribution = .fillEqually
        verticalStackView.spacing = gridSpacing
        verticalStackView.edgeInsets = contentInsets
        verticalStackView.translatesAutoresizingMaskIntoConstraints = true

        scrollView.documentView = verticalStackView
        visualEffectView.addSubview(scrollView)

        panel.contentView = visualEffectView
    }

    private func rebuildGrid(items: [HiddenItemInfo], notchRect: CGRect) {
        verticalStackView.arrangedSubviews.forEach { row in
            verticalStackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        let columns = max(1, maxColumns(for: notchRect.width))
        let rows = stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0 ..< min($0 + columns, items.count)])
        }

        for rowItems in rows {
            let rowStackView = NSStackView()
            rowStackView.orientation = .horizontal
            rowStackView.alignment = .centerY
            rowStackView.distribution = .fillEqually
            rowStackView.spacing = gridSpacing

            for item in rowItems {
                rowStackView.addArrangedSubview(makeButton(for: item))
            }

            if rowItems.count < columns {
                for _ in rowItems.count ..< columns {
                    let spacer = NSView(frame: NSRect(origin: .zero, size: cellSize))
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    spacer.widthAnchor.constraint(equalToConstant: cellSize.width).isActive = true
                    spacer.heightAnchor.constraint(equalToConstant: cellSize.height).isActive = true
                    rowStackView.addArrangedSubview(spacer)
                }
            }

            verticalStackView.addArrangedSubview(rowStackView)
        }

        if rows.isEmpty {
            let emptyRow = NSStackView()
            emptyRow.orientation = .horizontal
            emptyRow.alignment = .centerY
            emptyRow.addArrangedSubview(NSView(frame: NSRect(origin: .zero, size: cellSize)))
            verticalStackView.addArrangedSubview(emptyRow)
        }

        applyMaskImage()
    }

    private func makeButton(for item: HiddenItemInfo) -> NSButton {
        let button = HoverButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = item.name
        button.target = self
        button.action = #selector(itemButtonPressed(_:))
        button.hoverColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2)
        button.itemInfo = item
        button.widthAnchor.constraint(equalToConstant: cellSize.width).isActive = true
        button.heightAnchor.constraint(equalToConstant: cellSize.height).isActive = true

        if let icon = item.icon?.scaled(to: iconSize) {
            button.image = icon
        }

        return button
    }

    private func contentSize() -> NSSize {
        let fittingSize = verticalStackView.fittingSize
        let width = fittingSize.width
        let height = min(fittingSize.height, maxScrollHeight)
        scrollView.hasVerticalScroller = fittingSize.height > maxScrollHeight || rowCount() > maxVisibleRows
        verticalStackView.setFrameSize(NSSize(width: width, height: fittingSize.height))
        visualEffectView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        scrollView.frame = visualEffectView.bounds
        return NSSize(width: width, height: height)
    }

    private func rowCount() -> Int {
        verticalStackView.arrangedSubviews.count
    }

    private func frame(forContentSize size: NSSize, below notchRect: CGRect) -> CGRect {
        let width = size.width
        let height = size.height
        return CGRect(
            x: round(notchRect.midX - (width / 2)),
            y: round(notchRect.minY - height),
            width: width,
            height: height
        )
    }

    private func maxColumns(for notchWidth: CGFloat) -> Int {
        let usableWidth = max(notchWidth - contentInsets.left - contentInsets.right, cellSize.width)
        return max(1, Int((usableWidth + gridSpacing) / (cellSize.width + gridSpacing)))
    }

    private func applyMaskImage() {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()

            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: rect.maxY))
            path.line(to: NSPoint(x: 0, y: cornerRadius))
            path.appendArc(
                from: NSPoint(x: 0, y: 0),
                to: NSPoint(x: cornerRadius, y: 0),
                radius: cornerRadius
            )
            path.line(to: NSPoint(x: rect.maxX - cornerRadius, y: 0))
            path.appendArc(
                from: NSPoint(x: rect.maxX, y: 0),
                to: NSPoint(x: rect.maxX, y: cornerRadius),
                radius: cornerRadius
            )
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.close()

            NSColor.black.setFill()
            path.fill()
            return true
        }

        image.capInsets = NSEdgeInsets(top: size.height - 1, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        visualEffectView.maskImage = image
    }

    private func prepareForAnimation() -> UUID {
        let token = UUID()
        animationToken = token
        syncVisualStateFromPresentationLayer()
        visualEffectView.layer?.removeAllAnimations()
        return token
    }

    private func syncVisualStateFromPresentationLayer() {
        guard let presentation = visualEffectView.layer?.presentation(),
              let layer = visualEffectView.layer else { return }
        layer.opacity = presentation.opacity
        layer.transform = presentation.transform
    }

    private func animate(
        state: PanelState,
        fromOpacity: Float,
        toOpacity: Float,
        fromScale: CGFloat,
        toScale: CGFloat,
        completion: @escaping () -> Void
    ) {
        panelState = state

        guard let layer = visualEffectView.layer else {
            completion()
            return
        }

        layer.opacity = fromOpacity
        layer.transform = CATransform3DMakeScale(fromScale, fromScale, 1)

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = fromOpacity
        opacityAnimation.toValue = toOpacity
        opacityAnimation.duration = animationDuration
        opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let scaleAnimation = CABasicAnimation(keyPath: "transform")
        scaleAnimation.fromValue = CATransform3DMakeScale(fromScale, fromScale, 1)
        scaleAnimation.toValue = CATransform3DMakeScale(toScale, toScale, 1)
        scaleAnimation.duration = animationDuration
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.opacity = toOpacity
        layer.transform = CATransform3DMakeScale(toScale, toScale, 1)
        layer.add(opacityAnimation, forKey: "opacity")
        layer.add(scaleAnimation, forKey: "transform")
        CATransaction.commit()
    }

    private func completeHide() {
        panel.orderOut(nil)
        panelState = .hidden
        visualEffectView.layer?.opacity = 0
        visualEffectView.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
    }

    private func currentOpacity(from layer: CALayer?) -> Float? {
        layer?.opacity
    }

    private func currentScale(from layer: CALayer?) -> CGFloat? {
        guard let transform = layer?.transform else { return nil }
        return CGFloat(transform.m11)
    }

    @objc private func itemButtonPressed(_ sender: Any?) {
        guard let button = sender as? HoverButton,
              let item = button.itemInfo else { return }
        onItemSelected?(item)
    }
}

private final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class HoverButton: NSButton {
    var hoverColor: NSColor = .clear
    var itemInfo: HiddenItemInfo?

    private let backgroundView = NSView()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        backgroundView.layer?.cornerRadius = 8
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        backgroundView.layer?.backgroundColor = hoverColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func setup() {
        wantsLayer = true

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        backgroundView.layer?.cornerRadius = 8
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView, positioned: .below, relativeTo: imageView)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
