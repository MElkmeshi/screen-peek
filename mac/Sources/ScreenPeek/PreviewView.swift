import AppKit

final class PreviewView: NSView {
    var onClick: ((CGPoint, CGMouseButton, Int) -> Void)?
    var onScroll: ((CGPoint, CGFloat, CGFloat) -> Void)?
    var aspect = CGSize(width: 16, height: 9) { didSet { needsLayout = true } }

    private let imageLayer = CALayer()
    private let borderLayer = CALayer()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var flashOff: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        borderLayer.borderColor = NSColor.systemRed.cgColor
        borderLayer.borderWidth = 0
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(borderLayer)

        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        borderLayer.frame = contentRect()
        CATransaction.commit()
    }

    func show(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        CATransaction.commit()
        label.isHidden = true
    }

    func showMessage(_ message: String) {
        imageLayer.contents = nil
        label.stringValue = message
        label.isHidden = false
    }

    func flash() {
        flashOff?.cancel()
        borderLayer.borderWidth = 3
        let off = DispatchWorkItem { [weak self] in self?.borderLayer.borderWidth = 0 }
        flashOff = off
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: off)
    }

    func contentRect() -> CGRect {
        guard aspect.width > 0, aspect.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / aspect.width, bounds.height / aspect.height)
        let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func fraction(of event: NSEvent) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        let rect = contentRect()
        guard rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard let f = fraction(of: event) else { return }
        onClick?(f, .left, event.clickCount)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let f = fraction(of: event) else { return }
        onClick?(f, .right, event.clickCount)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let f = fraction(of: event) else { return }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        onScroll?(f, event.scrollingDeltaX * factor, event.scrollingDeltaY * factor)
    }
}
