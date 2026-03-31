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
    private let containerView = NSView()
    private let visualEffectView = NSVisualEffectView()
    private let tintView = NSView()
    private let borderLayer = CAShapeLayer()
    private let scrollView = NSScrollView()
    private let verticalStackView = NSStackView()

    private let desaturateFilter: CIFilter? = CIFilter(name: "CIColorControls")
    private var isActivated = false

    private var panelState: PanelState = .hidden
    private var animationToken = UUID()
    private var filterRemovalToken = UUID()

    /// The full target frame (extends up behind the notch so the background
    /// joins seamlessly). The panel window is always this size; we animate
    /// by clipping the visible portion.
    private var targetFrame: CGRect = .zero
    private var fullContentHeight: CGFloat = 0
    private var notchWidth: CGFloat = 0

    // MARK: - Layout Constants

    private let contentInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    private let cellSize = NSSize(width: 32, height: 32)
    private let iconSize = NSSize(width: 24, height: 24)
    private let gridSpacing: CGFloat = 8
    private let maxVisibleRows = 3
    private let maxScrollHeight: CGFloat = 160
    private let cornerRadius: CGFloat = 12
    private let borderWidth: CGFloat = 2
    private let showAnimationDuration: TimeInterval = 0.25
    private let hideAnimationDuration: TimeInterval = 0.18

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

        // Listen for when the panel becomes key (user clicked into it)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelBecameKey),
            name: NSWindow.didBecomeKeyNotification,
            object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func show(items: [HiddenItemInfo], below notchRect: CGRect) {
        guard !items.isEmpty else {
            snugLog(" NotchDropdownPanel.show: no items, skipping")
            hide(animated: false)
            return
        }

        snugLog(" NotchDropdownPanel.show: items=%d, state=%@",
              items.count, "\(panelState)")

        notchWidth = notchRect.width
        rebuildGrid(items: items, notchRect: notchRect)
        let size = contentSize()
        fullContentHeight = size.height

        targetFrame = CGRect(
            x: notchRect.origin.x,
            y: round(notchRect.minY - size.height),
            width: notchWidth,
            height: size.height
        )

        // Set the panel to full target frame always
        panel.setFrame(targetFrame, display: false)
        panel.alphaValue = 1

        // Start greyscale — user clicks into pocket to activate
        applyGreyscale()

        // Position content at the top of the panel (it will be clipped)
        containerView.frame = NSRect(origin: .zero, size: targetFrame.size)
        visualEffectView.frame = containerView.bounds
        scrollView.frame = containerView.bounds
        updateBorderPath()

        let token = UUID()
        animationToken = token

        if !shouldAnimateTransitions {
            // No animation — show fully
            panel.contentView?.layer?.mask = nil
            panel.orderFront(nil)
            panelState = .visible
            snugLog(" NotchDropdownPanel: state → visible (no animation)")
            return
        }

        // Clip mask anchored to top — animate height from 0 to full
        let maskLayer = CALayer()
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.anchorPoint = CGPoint(x: 0.5, y: 1) // anchor at top edge (layer coords: y=1 is top)
        maskLayer.bounds = CGRect(x: 0, y: 0, width: targetFrame.width, height: 0)
        maskLayer.position = CGPoint(x: targetFrame.width / 2, y: fullContentHeight) // top center
        panel.contentView?.layer?.mask = maskLayer
        panel.orderFront(nil)

        panelState = .showing

        // Animate bounds height from 0 → full (reveals content sliding down from notch)
        let anim = CABasicAnimation(keyPath: "bounds.size.height")
        anim.fromValue = 0
        anim.toValue = fullContentHeight
        anim.duration = showAnimationDuration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.animationToken == token else { return }
            self.panel.contentView?.layer?.mask = nil
            self.panelState = .visible
            snugLog(" NotchDropdownPanel: state → visible")
        }

        maskLayer.add(anim, forKey: "revealHeight")

        CATransaction.commit()
    }

    func hide(animated: Bool) {
        guard panelState != .hidden else { return }

        snugLog(" NotchDropdownPanel.hide: animated=%d, state=%@",
              animated ? 1 : 0, "\(panelState)")

        if !animated || !shouldAnimateTransitions {
            completeHide()
            return
        }

        let token = UUID()
        animationToken = token
        panelState = .hiding

        // Clip mask anchored to top — animate height from full to 0 (slides up into notch)
        let maskLayer = CALayer()
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.anchorPoint = CGPoint(x: 0.5, y: 1)
        maskLayer.bounds = CGRect(x: 0, y: 0, width: targetFrame.width, height: fullContentHeight)
        maskLayer.position = CGPoint(x: targetFrame.width / 2, y: fullContentHeight)
        panel.contentView?.layer?.mask = maskLayer

        let anim = CABasicAnimation(keyPath: "bounds.size.height")
        anim.fromValue = fullContentHeight
        anim.toValue = 0
        anim.duration = hideAnimationDuration
        anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.animationToken == token else { return }
            self.completeHide()
        }

        maskLayer.add(anim, forKey: "hideHeight")

        CATransaction.commit()
    }

    // MARK: - Panel Setup

    private func setupPanel() {
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = false
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
        // Container clips everything
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = true

        // Frosted dark background
        visualEffectView.material = .dark
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true

        // All corners rounded
        visualEffectView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.masksToBounds = true

        // Dark tint overlay
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        tintView.autoresizingMask = [.width, .height]

        // U-shaped border (sides + bottom, not top)
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
        borderLayer.lineWidth = borderWidth

        // Scroll view (needs layer for CI filters)
        scrollView.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        // Grid
        verticalStackView.orientation = .vertical
        verticalStackView.alignment = .centerX
        verticalStackView.distribution = .fillEqually
        verticalStackView.spacing = gridSpacing
        verticalStackView.edgeInsets = contentInsets
        verticalStackView.translatesAutoresizingMaskIntoConstraints = true

        scrollView.documentView = verticalStackView
        visualEffectView.addSubview(tintView)
        visualEffectView.addSubview(scrollView)
        containerView.addSubview(visualEffectView)
        containerView.layer?.addSublayer(borderLayer)

        // The panel's contentView needs a layer for masking
        let hostView = NSView()
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.addSubview(containerView)
        panel.contentView = hostView
    }

    private func updateBorderPath() {
        let bounds = CGRect(origin: .zero, size: targetFrame.size)
        let cr = cornerRadius
        let inset = borderWidth / 2

        let path = CGMutablePath()
        // Full rounded rectangle border (all four corners)
        path.addRoundedRect(in: bounds.insetBy(dx: inset, dy: inset),
                            cornerWidth: cr, cornerHeight: cr)
        borderLayer.path = path
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
            rowStackView.distribution = .fill
            rowStackView.spacing = gridSpacing

            for item in rowItems {
                rowStackView.addArrangedSubview(makeButton(for: item))
            }

            verticalStackView.addArrangedSubview(rowStackView)
        }
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
        button.hoverColor = NSColor.white.withAlphaComponent(0.1)
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
        let width = notchWidth
        let height = min(fittingSize.height, maxScrollHeight)
        scrollView.hasVerticalScroller = fittingSize.height > maxScrollHeight || rowCount() > maxVisibleRows
        verticalStackView.setFrameSize(NSSize(width: width, height: fittingSize.height))

        // Center each row horizontally within the full notch width
        for row in verticalStackView.arrangedSubviews {
            let rowWidth = row.fittingSize.width
            let xOffset = round((width - rowWidth) / 2)
            row.frame.origin.x = xOffset
        }

        return NSSize(width: width, height: height)
    }

    private func rowCount() -> Int {
        verticalStackView.arrangedSubviews.count
    }

    private func maxColumns(for notchWidth: CGFloat) -> Int {
        let usableWidth = max(notchWidth - contentInsets.left - contentInsets.right, cellSize.width)
        return max(1, Int((usableWidth + gridSpacing) / (cellSize.width + gridSpacing)))
    }

    // MARK: - Animation Helpers

    private func completeHide() {
        panel.contentView?.layer?.mask = nil
        panel.orderOut(nil)
        panelState = .hidden
        isActivated = false
        filterRemovalToken = UUID()
        scrollView.layer?.filters = nil
        snugLog(" NotchDropdownPanel: state → hidden")
    }

    private var shouldAnimateTransitions: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Greyscale / Activation

    private func applyGreyscale() {
        isActivated = false
        filterRemovalToken = UUID()
        guard let filter = desaturateFilter else { return }
        filter.setValue(0, forKey: kCIInputSaturationKey) // fully desaturated
        filter.setValue(-0.05, forKey: kCIInputBrightnessKey) // slightly dimmer
        scrollView.layer?.filters = [filter]
    }

    private func setButtonHoverEnabled(_ enabled: Bool) {
        for row in verticalStackView.arrangedSubviews {
            guard let rowStack = row as? NSStackView else { continue }
            for view in rowStack.arrangedSubviews {
                (view as? HoverButton)?.hoverEnabled = enabled
            }
        }
    }

    private func removeGreyscale(animated: Bool) {
        guard !isActivated else { return }
        isActivated = true
        setButtonHoverEnabled(true)

        if !animated {
            scrollView.layer?.filters = nil
            return
        }

        // Animate saturation back to full colour
        guard let filter = desaturateFilter else {
            scrollView.layer?.filters = nil
            return
        }

        // Transition: animate from 0 saturation to 1
        let satAnim = CABasicAnimation(keyPath: "filters.colorControls.inputSaturation")
        satAnim.fromValue = 0
        satAnim.toValue = 1
        satAnim.duration = 0.25
        satAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let brightAnim = CABasicAnimation(keyPath: "filters.colorControls.inputBrightness")
        brightAnim.fromValue = -0.05
        brightAnim.toValue = 0
        brightAnim.duration = 0.25
        brightAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        // Set final state
        filter.setValue(1, forKey: kCIInputSaturationKey)
        filter.setValue(0, forKey: kCIInputBrightnessKey)
        scrollView.layer?.filters = [filter]

        scrollView.layer?.add(satAnim, forKey: "saturationIn")
        scrollView.layer?.add(brightAnim, forKey: "brightnessIn")

        // Remove filter entirely after animation
        let token = UUID()
        filterRemovalToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.filterRemovalToken == token else { return }
            self.scrollView.layer?.filters = nil
        }
    }

    @objc private func panelBecameKey() {
        removeGreyscale(animated: true)
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

    /// Allow the panel to extend into the menu bar / notch area.
    /// macOS normally constrains windows to stay below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class HoverButton: NSButton {
    var hoverColor: NSColor = .clear
    var hoverEnabled: Bool = false
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
        backgroundView.layer?.cornerRadius = 6
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard hoverEnabled else { return }
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
        backgroundView.layer?.cornerRadius = 6
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView, positioned: .below, relativeTo: self.subviews.first)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
