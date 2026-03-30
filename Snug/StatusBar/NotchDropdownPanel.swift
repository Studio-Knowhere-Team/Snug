import AppKit
import QuartzCore

@MainActor
final class NotchDropdownPanel: NSObject {

    // MARK: - State

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

    // MARK: - UI Elements

    private let panel: PanelWindow
    private let visualEffectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let verticalStackView = NSStackView()

    private var panelState: PanelState = .hidden
    private var animationToken = UUID()

    // MARK: - Layout Constants

    private let contentInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    private let cellSize = NSSize(width: 32, height: 32)
    private let iconSize = NSSize(width: 24, height: 24)
    private let gridSpacing: CGFloat = 8
    private let maxVisibleRows = 3
    private let maxScrollHeight: CGFloat = 160
    private let cornerRadius: CGFloat = 12
    private let showAnimationDuration: TimeInterval = 0.2
    private let hideAnimationDuration: TimeInterval = 0.15
    private let hiddenYOffset: CGFloat = -4

    // MARK: - Init

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

    // MARK: - Public API

    func show(items: [HiddenItemInfo], below notchRect: CGRect) {
        guard !items.isEmpty else {
            snugLog(" NotchDropdownPanel.show: no items, skipping")
            hide(animated: false)
            return
        }

        snugLog(" NotchDropdownPanel.show: items=%d, notch=(%.0f, %.0f, %.0f, %.0f), state=%@",
              items.count, notchRect.origin.x, notchRect.origin.y,
              notchRect.width, notchRect.height, "\(panelState)")

        rebuildGrid(items: items, notchRect: notchRect)
        let targetFrame = frame(forContentSize: contentSize(), below: notchRect)

        let token = prepareForAnimation()
        let startingTranslationY = currentTranslationY(from: visualEffectView.layer?.presentation()) ?? currentTranslationY(from: visualEffectView.layer) ?? hiddenYOffset
        let startingOpacity = currentOpacity(from: visualEffectView.layer?.presentation()) ?? currentOpacity(from: visualEffectView.layer) ?? 0

        panel.setContentSize(targetFrame.size)
        panel.setFrame(targetFrame, display: false)
        panel.orderFront(nil)
        panel.alphaValue = 1

        if !shouldAnimateTransitions {
            panelState = .visible
            visualEffectView.alphaValue = 1
            visualEffectView.layer?.opacity = 1
            visualEffectView.layer?.transform = CATransform3DIdentity
            snugLog(" NotchDropdownPanel: state → visible")
            return
        }

        animateShow(token: token, fromOpacity: startingOpacity, fromTranslationY: startingTranslationY)
    }

    func hide(animated: Bool) {
        guard panelState != .hidden else { return }

        snugLog(" NotchDropdownPanel.hide: animated=%d, state=%@",
              animated ? 1 : 0, "\(panelState)")

        if !animated || !shouldAnimateTransitions {
            completeHide()
            return
        }

        let token = prepareForAnimation()
        let startingOpacity = currentOpacity(from: visualEffectView.layer?.presentation()) ?? currentOpacity(from: visualEffectView.layer) ?? 1
        let startingTranslationY = currentTranslationY(from: visualEffectView.layer?.presentation()) ?? currentTranslationY(from: visualEffectView.layer) ?? 0

        animateHide(token: token, fromOpacity: startingOpacity, fromTranslationY: startingTranslationY)
    }

    // MARK: - Panel Setup

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
        visualEffectView.alphaValue = 0
        visualEffectView.layer?.opacity = 0
        visualEffectView.layer?.transform = hiddenTransform

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

    // MARK: - Grid Layout

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

    // MARK: - Mask

    private func applyMaskImage() {
        let size = cellSize
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

    // MARK: - Animation

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
        visualEffectView.alphaValue = CGFloat(presentation.opacity)
    }

    private func animateShow(
        token: UUID,
        fromOpacity: Float,
        fromTranslationY: CGFloat
    ) {
        panelState = .showing
        visualEffectView.alphaValue = CGFloat(fromOpacity)
        visualEffectView.layer?.opacity = fromOpacity
        visualEffectView.layer?.transform = translationTransform(y: fromTranslationY)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = showAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            visualEffectView.animator().alphaValue = 1
            visualEffectView.layer?.animator().opacity = 1
            visualEffectView.layer?.animator().transform = CATransform3DIdentity
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.animationToken == token else { return }
                self.panelState = .visible
                snugLog(" NotchDropdownPanel: state → visible")
            }
        }
    }

    private func animateHide(
        token: UUID,
        fromOpacity: Float,
        fromTranslationY: CGFloat
    ) {
        panelState = .hiding
        visualEffectView.alphaValue = CGFloat(fromOpacity)
        visualEffectView.layer?.opacity = fromOpacity
        visualEffectView.layer?.transform = translationTransform(y: fromTranslationY)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = hideAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            visualEffectView.animator().alphaValue = 0
            visualEffectView.layer?.animator().opacity = 0
            visualEffectView.layer?.animator().transform = hiddenTransform
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.animationToken == token else { return }
                self.completeHide()
            }
        }
    }

    private func completeHide() {
        panel.orderOut(nil)
        panelState = .hidden
        visualEffectView.alphaValue = 0
        visualEffectView.layer?.opacity = 0
        visualEffectView.layer?.transform = hiddenTransform
        snugLog(" NotchDropdownPanel: state → hidden")
    }

    private func currentOpacity(from layer: CALayer?) -> Float? {
        layer?.opacity
    }

    private func currentTranslationY(from layer: CALayer?) -> CGFloat? {
        guard let transform = layer?.transform else { return nil }
        return CGFloat(transform.m42)
    }

    private var shouldAnimateTransitions: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var hiddenTransform: CATransform3D {
        translationTransform(y: hiddenYOffset)
    }

    private func translationTransform(y: CGFloat) -> CATransform3D {
        CATransform3DMakeTranslation(0, y, 0)
    }

    // MARK: - Actions

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
