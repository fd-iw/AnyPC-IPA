import UIKit

enum ControlMode: String {
    /// Finger moves the cursor relatively, like a laptop trackpad (best on small screens).
    case trackpad
    /// Tap exactly where you want to click.
    case touch
}

/// Shows the PC screen and turns gestures into mouse input.
///
/// Trackpad mode: drag = move cursor, tap = click, two-finger tap = right-click,
/// press-and-hold then drag = drag, two-finger drag = scroll, pinch = zoom (view follows cursor).
///
/// Touch mode: tap = click there, long-press = right-click there, drag = drag,
/// two-finger drag = scroll (or pan when zoomed), pinch = zoom.
final class RemoteScreenView: UIView, UIGestureRecognizerDelegate {
    weak var conn: PCConnection?
    var mode: ControlMode = .trackpad
    var sensitivity: CGFloat = 1.3

    let keyboard = KeyboardProxyView()

    private let imageLayer = CALayer()
    private let placeholder = UILabel()
    private var imageSize: CGSize = .zero
    private var cursor: CGPoint?
    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var moveRemainder: CGPoint = .zero
    private var scrollRemainder: CGPoint = .zero
    private var lastHoldPoint: CGPoint = .zero

    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
    private lazy var twoFingerPan: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan(_:)))
        g.minimumNumberOfTouches = 2
        g.maximumNumberOfTouches = 2
        return g
    }()

    init(conn: PCConnection) {
        self.conn = conn
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        clipsToBounds = true

        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        layer.addSublayer(imageLayer)

        placeholder.text = "Waiting for the screen…"
        placeholder.textColor = UIColor(white: 1, alpha: 0.6)
        placeholder.font = .preferredFont(forTextStyle: .subheadline)
        placeholder.textAlignment = .center
        addSubview(placeholder)

        keyboard.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        keyboard.alpha = 0.01
        addSubview(keyboard)

        setupGestures()

        conn.onFrame = { [weak self] image, cursor in self?.show(image, cursor: cursor) }
        if let img = conn.lastFrame { show(img, cursor: conn.lastCursor) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Rendering

    func show(_ image: UIImage, cursor: CGPoint?) {
        placeholder.isHidden = true
        let sizeChanged = image.size != imageSize
        imageSize = image.size
        self.cursor = cursor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image.cgImage
        if sizeChanged { layoutImage() }
        if mode == .trackpad && zoom > 1.01 { followCursor() }
        CATransaction.commit()
    }

    func resetZoom() {
        zoom = 1
        pan = .zero
        layoutImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = bounds
        clampPan()
        layoutImage()
    }

    /// Aspect-fit rectangle of the screen image at zoom 1.
    private var fitRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0 else { return bounds }
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * s
        let h = imageSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private var displayRect: CGRect {
        let f = fitRect
        let w = f.width * zoom
        let h = f.height * zoom
        return CGRect(x: bounds.midX - w / 2 + pan.x, y: bounds.midY - h / 2 + pan.y, width: w, height: h)
    }

    private func clampPan() {
        let f = fitRect
        let maxX = max(0, (f.width * zoom - bounds.width) / 2)
        let maxY = max(0, (f.height * zoom - bounds.height) / 2)
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
    }

    private func layoutImage() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = displayRect
        CATransaction.commit()
    }

    /// Keeps the cursor visible when zoomed in trackpad mode.
    private func followCursor() {
        guard let c = cursor, imageSize.width > 0 else { return }
        let r = displayRect
        let p = CGPoint(x: r.minX + c.x / imageSize.width * r.width, y: r.minY + c.y / imageSize.height * r.height)
        let margin = CGSize(width: bounds.width * 0.2, height: bounds.height * 0.2)
        if p.x < margin.width { pan.x += margin.width - p.x }
        if p.x > bounds.width - margin.width { pan.x -= p.x - (bounds.width - margin.width) }
        if p.y < margin.height { pan.y += margin.height - p.y }
        if p.y > bounds.height - margin.height { pan.y -= p.y - (bounds.height - margin.height) }
        clampPan()
        layoutImage()
    }

    /// View point → normalized (0–1) position on the PC monitor.
    private func normalized(_ p: CGPoint) -> CGPoint {
        let r = displayRect
        guard r.width > 0, r.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max((p.x - r.minX) / r.width, 0), 1), y: min(max((p.y - r.minY) / r.height, 0), 1))
    }

    /// PC pixels per point of finger travel in trackpad mode.
    private var pcPixelsPerPoint: CGFloat {
        guard let conn = conn, bounds.width > 0 else { return 1 }
        let width = conn.monitors.indices.contains(conn.currentMonitor) ? CGFloat(conn.monitors[conn.currentMonitor].width) : imageSize.width
        return max(width, 640) / bounds.width
    }

    // MARK: - Gestures

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let onePan = UIPanGestureRecognizer(target: self, action: #selector(onOneFingerPan(_:)))
        onePan.maximumNumberOfTouches = 1
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        hold.minimumPressDuration = 0.4

        pinch.delegate = self
        twoFingerPan.delegate = self
        [tap, twoFingerTap, onePan, hold, pinch, twoFingerPan].forEach(addGestureRecognizer)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // In touch mode pinch-zoom and two-finger panning of the zoomed view work together.
        let pair: Set<UIGestureRecognizer> = [pinch, twoFingerPan]
        return mode == .touch && pair.contains(g) && pair.contains(other)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard let conn = conn else { return }
        if mode == .touch { conn.move(normalized(g.location(in: self))) }
        conn.button("left", "click")
    }

    @objc private func onTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard let conn = conn else { return }
        if mode == .touch { conn.move(normalized(g.location(in: self))) }
        conn.button("right", "click")
    }

    @objc private func onOneFingerPan(_ g: UIPanGestureRecognizer) {
        guard let conn = conn else { return }
        switch mode {
        case .trackpad:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            let v = g.velocity(in: self)
            let speed = hypot(v.x, v.y)
            let accel = 1 + min(speed / 900, 2.5)
            let scale = pcPixelsPerPoint * sensitivity * 0.6 * accel
            moveRelative(t.x * scale, t.y * scale)
        case .touch:
            let p = g.location(in: self)
            switch g.state {
            case .began:
                let t = g.translation(in: self)
                conn.move(normalized(CGPoint(x: p.x - t.x, y: p.y - t.y)))
                conn.button("left", "down")
                conn.move(normalized(p))
            case .changed:
                conn.move(normalized(p))
            case .ended, .cancelled, .failed:
                conn.move(normalized(p))
                conn.button("left", "up")
            default:
                break
            }
        }
    }

    @objc private func onHold(_ g: UILongPressGestureRecognizer) {
        guard let conn = conn else { return }
        let p = g.location(in: self)
        switch mode {
        case .trackpad:
            // Press and hold, then drag: moves with the left button held down.
            switch g.state {
            case .began:
                lastHoldPoint = p
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                conn.button("left", "down")
            case .changed:
                let scale = pcPixelsPerPoint * sensitivity
                moveRelative((p.x - lastHoldPoint.x) * scale, (p.y - lastHoldPoint.y) * scale)
                lastHoldPoint = p
            case .ended, .cancelled, .failed:
                conn.button("left", "up")
            default:
                break
            }
        case .touch:
            if g.state == .began {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                conn.move(normalized(p))
                conn.button("right", "click")
            }
        }
    }

    @objc private func onTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if mode == .touch && zoom > 1.01 {
            pan.x += t.x
            pan.y += t.y
            clampPan()
            layoutImage()
            return
        }
        // Natural scrolling: content follows the fingers. 120 = one wheel notch.
        scrollRemainder.x += -t.x * 4
        scrollRemainder.y += t.y * 4
        let dx = Int(scrollRemainder.x)
        let dy = Int(scrollRemainder.y)
        if dx != 0 || dy != 0 {
            scrollRemainder.x -= CGFloat(dx)
            scrollRemainder.y -= CGFloat(dy)
            conn?.wheel(dx: dx, dy: dy)
        }
        if g.state == .ended || g.state == .cancelled { scrollRemainder = .zero }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        let loc = g.location(in: self)
        let before = displayRect
        guard before.width > 0, before.height > 0 else { return }
        let rel = CGPoint(x: (loc.x - before.minX) / before.width, y: (loc.y - before.minY) / before.height)
        zoom = min(max(zoom * g.scale, 1), 6)
        g.scale = 1
        let after = displayRect
        pan.x += loc.x - (after.minX + rel.x * after.width)
        pan.y += loc.y - (after.minY + rel.y * after.height)
        clampPan()
        layoutImage()
    }

    private func moveRelative(_ dx: CGFloat, _ dy: CGFloat) {
        moveRemainder.x += dx
        moveRemainder.y += dy
        let ix = Int(moveRemainder.x)
        let iy = Int(moveRemainder.y)
        guard ix != 0 || iy != 0 else { return }
        moveRemainder.x -= CGFloat(ix)
        moveRemainder.y -= CGFloat(iy)
        conn?.moveRelative(dx: ix, dy: iy)
    }
}
