import AppKit

/// Borderless, transparent, always-on-top panel exactly the size of one sprite
/// frame. It never takes focus, follows you to whichever Space you switch to (running
/// in from the side, see PetController.spaceChanged), and lets clicks through
/// except on the cat's visible pixels (see PetController.updateMousePassThrough).
final class PetWindow: NSPanel {
    let spriteView = SpriteView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 144, height: 144),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Not on every Space at once: it stays behind on the old desktop as you swipe away,
        // then is moved to the new one and dashes in.
        collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle]
        isMovable = false // We move it ourselves; macOS must not drag it.
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = spriteView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws one sprite frame with nearest-neighbour scaling, or a labelled placeholder.
final class SpriteView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    private let imageLayer = CALayer()
    private let placeholderBox = CAShapeLayer()
    private let placeholderText = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        imageLayer.magnificationFilter = .nearest // Crisp pixels, never blurred.
        imageLayer.minificationFilter = .nearest
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)

        placeholderBox.fillColor = NSColor(calibratedWhite: 0.1, alpha: 0.75).cgColor
        placeholderBox.strokeColor = NSColor.systemYellow.cgColor
        placeholderBox.lineWidth = 2
        placeholderBox.lineDashPattern = [6, 4]
        layer?.addSublayer(placeholderBox)

        placeholderText.alignmentMode = .center
        placeholderText.foregroundColor = NSColor.systemYellow.cgColor
        placeholderText.isWrapped = true
        placeholderText.font = NSFont.boldSystemFont(ofSize: 11)
        layer?.addSublayer(placeholderText)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }

    private let clipMask = CALayer()

    /// Only show this part of the view (in view coordinates), or everything when nil.
    func clip(to rect: NSRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let rect else { layer?.mask = nil; return }
        clipMask.backgroundColor = NSColor.black.cgColor
        clipMask.frame = rect.isNull ? .zero : rect
        if layer?.mask !== clipMask { layer?.mask = clipMask }
    }

    /// `lean` tilts the cat around its feet (radians), e.g. while riding a moving window.
    func show(_ frame: SpriteFrame, facingRight: Bool, lean: Double = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let b = bounds
        if let image = frame.image {
            imageLayer.isHidden = false
            placeholderBox.isHidden = true
            placeholderText.isHidden = true
            imageLayer.setAffineTransform(.identity)
            imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
            imageLayer.frame = b
            imageLayer.contents = image
            imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: lean).scaledBy(x: facingRight ? 1 : -1, y: 1))
        } else {
            imageLayer.isHidden = true
            placeholderBox.isHidden = false
            placeholderText.isHidden = false
            let box = b.insetBy(dx: 3, dy: 3)
            placeholderBox.path = CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)
            let fontSize = max(8, min(13, b.width / 11))
            placeholderText.fontSize = fontSize
            placeholderText.contentsScale = window?.backingScaleFactor ?? 2
            placeholderText.string = frame.placeholderText ?? "No art"
            placeholderText.frame = CGRect(x: box.minX + 4, y: box.midY - fontSize * 1.6, width: box.width - 8, height: fontSize * 3.4)
        }
    }
}

/// A floor prop (bowl or yarn ball): pixel art at the cat's scale, never takes clicks.
final class PropWindow: NSPanel {
    private let imageLayer = CALayer()

    init(image: CGImage, scale: CGFloat) {
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        imageLayer.magnificationFilter = .nearest
        imageLayer.contentsGravity = .resize
        imageLayer.frame = view.bounds
        imageLayer.contents = image
        view.layer?.addSublayer(imageLayer)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Swap art or size (after switching cats or changing scale).
    func update(image: CGImage, scale: CGFloat) {
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setContentSize(size)
        contentView?.frame = NSRect(origin: .zero, size: size)
        imageLayer.frame = NSRect(origin: .zero, size: size)
        imageLayer.contents = image
        CATransaction.commit()
    }

    /// Rotate in exact quarter turns, which keeps the pixels crisp.
    func setQuarterTurns(_ turns: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        CATransaction.commit()
    }
}
