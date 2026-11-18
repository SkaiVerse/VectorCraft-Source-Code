import UIKit

private let panelColor = UIColor(white: 0.13, alpha: 0.94)
private let borderColor = UIColor(white: 1, alpha: 0.16)

// MARK: - Arc tool menu (Apple Pencil squeeze)

/// A slim strip of tools curving over the point where the pencil was squeezed. The strip is one
/// colour; the tool under the pencil (hovering) or finger gets a circle around it and its name.
final class ArcMenuView: UIView {
    struct Item {
        let title: String
        let symbol: String
        /// The ids to try, in order (the first one the app knows is used).
        let tools: [String]
    }

    var onPick: (([String]) -> Void)?
    var onDismiss: (() -> Void)?

    private let items: [Item]
    private let anchor: CGPoint
    private var buttons: [UIButton] = []
    private var rings: [UIView] = []
    private let label = UILabel()
    private let labelPill = UIView()

    private let radius: CGFloat = 104
    private let iconSize: CGFloat = 42
    private let thickness: CGFloat = 60

    init(frame: CGRect, anchor: CGPoint, items: [Item]) {
        self.items = items
        self.anchor = anchor
        super.init(frame: frame)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let above = anchor.y > 230
        // The strip sweeps 190 degrees, centred straight up (or straight down).
        let centre: CGFloat = above ? -CGFloat.pi / 2 : CGFloat.pi / 2
        let half: CGFloat = 95 * CGFloat.pi / 180
        let start = centre - half
        let end = centre + half

        let strip = CAShapeLayer()
        strip.path = UIBezierPath(arcCenter: anchor, radius: radius, startAngle: start, endAngle: end, clockwise: true).cgPath
        strip.strokeColor = UIColor(white: 0.15, alpha: 0.97).cgColor
        strip.fillColor = UIColor.clear.cgColor
        strip.lineWidth = thickness
        strip.lineCap = .round
        strip.shadowColor = UIColor.black.cgColor
        strip.shadowOpacity = 0.35
        strip.shadowRadius = 10
        strip.shadowOffset = CGSize(width: 0, height: 3)
        layer.addSublayer(strip)

        let count = items.count
        for (i, item) in items.enumerated() {
            let t = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 0.5
            let angle = start + (end - start) * t
            var c = CGPoint(x: anchor.x + radius * cos(angle), y: anchor.y + radius * sin(angle))
            c.x = min(max(c.x, 30), bounds.width - 30)
            c.y = min(max(c.y, 30), bounds.height - 30)

            // The circle that shows which tool the pencil is over.
            let ring = UIView(frame: CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
            ring.center = c
            ring.layer.cornerRadius = iconSize / 2
            ring.backgroundColor = UIColor(white: 1, alpha: 0.12)
            ring.layer.borderWidth = 2
            ring.layer.borderColor = UIColor.systemBlue.cgColor
            ring.alpha = 0
            ring.isUserInteractionEnabled = false
            addSubview(ring)
            rings.append(ring)

            let b = UIButton(type: .custom)
            b.frame = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
            b.center = c
            b.setImage(UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)), for: .normal)
            b.tintColor = .white
            b.tag = i
            b.addTarget(self, action: #selector(down(_:)), for: .touchDown)
            b.addTarget(self, action: #selector(up(_:)), for: [.touchUpOutside, .touchCancel])
            b.addTarget(self, action: #selector(picked(_:)), for: .touchUpInside)
            b.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
            addSubview(b)
            buttons.append(b)
        }

        // The tool's name, just outside the strip.
        labelPill.backgroundColor = UIColor(white: 0.15, alpha: 0.97)
        labelPill.layer.cornerRadius = 13
        labelPill.alpha = 0
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        label.textAlignment = .center
        labelPill.addSubview(label)
        addSubview(labelPill)
    }

    private func show(_ i: Int?) {
        for (k, ring) in rings.enumerated() { ring.alpha = (k == i) ? 1 : 0 }
        guard let i = i else { labelPill.alpha = 0; return }
        label.text = items[i].title
        label.sizeToFit()
        let w = label.bounds.width + 24
        labelPill.bounds = CGRect(x: 0, y: 0, width: w, height: 26)
        label.frame = labelPill.bounds
        let above = anchor.y > 230
        let y = above ? anchor.y - radius - thickness / 2 - 24 : anchor.y + radius + thickness / 2 + 24
        labelPill.center = CGPoint(x: min(max(anchor.x, w / 2 + 8), bounds.width - w / 2 - 8), y: min(max(y, 20), bounds.height - 20))
        labelPill.alpha = 1
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard let b = g.view else { return }
        switch g.state {
        case .began, .changed: show(b.tag)
        default: show(nil)
        }
    }

    @objc private func down(_ b: UIButton) { show(b.tag) }
    @objc private func up(_ b: UIButton) { show(nil) }
    @objc private func picked(_ b: UIButton) { onPick?(items[b.tag].tools) }

    // A tap anywhere else closes the menu.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onDismiss?()
    }
}

// MARK: - Assistive Touch (modifier keys on screen)

/// A round button you can drag anywhere. Tap it and a ring of four keys opens round it: Shift
/// (top), Command (right), Option (bottom) and Control (left). Each key latches; several can be on
/// at once, as when holding them on a keyboard. A small hand switches "draw with finger".
final class AssistiveTouchView: UIView {
    var onMods: ((UInt32) -> Void)?
    var onFingerDraw: ((Bool) -> Void)?

    private let main = UIButton(type: .custom)
    private let hand = UIButton(type: .custom)
    private let ringLayer = CALayer()
    private var wedges: [CAShapeLayer] = []
    private var wedgePaths: [UIBezierPath] = []
    private var glyphs: [UILabel] = []

    // top, right, bottom, left
    private let bits: [UInt32] = [1, 8, 4, 2]
    private let marks = ["⇧", "⌘", "⌥", "⌃"]
    private let mids: [CGFloat] = [-CGFloat.pi / 2, 0, CGFloat.pi / 2, CGFloat.pi]

    private var expanded = false
    private var active: UInt32 = 0
    private(set) var fingerDrawOn = false

    private let off = UIColor(red: 0.10, green: 0.20, blue: 0.28, alpha: 0.82)
    private let on = UIColor(red: 0.12, green: 0.62, blue: 0.95, alpha: 0.96)

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 224, height: 224))
        backgroundColor = .clear
        let c = CGPoint(x: bounds.midX, y: bounds.midY)

        ringLayer.frame = bounds
        ringLayer.opacity = 0
        layer.addSublayer(ringLayer)

        for i in 0..<4 {
            let path = wedge(center: c, inner: 38, outer: 88, mid: mids[i], half: 40 * CGFloat.pi / 180)
            wedgePaths.append(path)
            let shape = CAShapeLayer()
            shape.path = path.cgPath
            shape.fillColor = off.cgColor
            ringLayer.addSublayer(shape)
            wedges.append(shape)

            let g = UILabel()
            g.text = marks[i]
            g.font = UIFont.systemFont(ofSize: 24, weight: .semibold)
            g.textColor = UIColor(white: 0.85, alpha: 0.9)
            g.sizeToFit()
            g.center = CGPoint(x: c.x + 63 * cos(mids[i]), y: c.y + 63 * sin(mids[i]))
            g.isUserInteractionEnabled = false
            g.alpha = 0
            addSubview(g)
            glyphs.append(g)
        }

        main.frame = CGRect(x: 0, y: 0, width: 58, height: 58)
        main.center = c
        main.backgroundColor = UIColor(white: 0.40, alpha: 0.60)
        main.layer.cornerRadius = 29
        main.layer.borderWidth = 5
        main.layer.borderColor = UIColor(white: 0.9, alpha: 0.92).cgColor
        main.addTarget(self, action: #selector(toggleRing), for: .touchUpInside)
        main.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        addSubview(main)

        hand.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        hand.center = CGPoint(x: c.x + 82, y: c.y - 82)
        hand.backgroundColor = panelColor
        hand.layer.cornerRadius = 20
        hand.layer.borderWidth = 1
        hand.layer.borderColor = borderColor.cgColor
        hand.tintColor = .white
        hand.setImage(UIImage(systemName: "hand.point.up.left.fill"), for: .normal)
        hand.alpha = 0
        hand.isHidden = true
        hand.addTarget(self, action: #selector(handTapped), for: .touchUpInside)
        addSubview(hand)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func wedge(center: CGPoint, inner: CGFloat, outer: CGFloat, mid: CGFloat, half: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        p.addArc(withCenter: center, radius: outer, startAngle: mid - half, endAngle: mid + half, clockwise: true)
        p.addArc(withCenter: center, radius: inner, startAngle: mid + half, endAngle: mid - half, clockwise: false)
        p.close()
        return p
    }

    /// Only the buttons and the ring take touches; the rest lets them through to the canvas.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !hand.isHidden, hand.frame.contains(point) { return hand }
        if main.frame.contains(point) { return main }
        if expanded, wedgePaths.contains(where: { $0.contains(point) }) { return self }
        return nil
    }

    func setFingerDraw(_ on: Bool) {
        fingerDrawOn = on
        hand.backgroundColor = on ? UIColor.systemBlue : panelColor
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, w) in wedges.enumerated() {
            w.fillColor = ((active & bits[i]) != 0 ? on : off).cgColor
            glyphs[i].textColor = (active & bits[i]) != 0 ? .white : UIColor(white: 0.85, alpha: 0.9)
        }
        CATransaction.commit()
        main.backgroundColor = active != 0 ? UIColor.systemBlue.withAlphaComponent(0.55) : UIColor(white: 0.40, alpha: 0.60)
    }

    @objc private func toggleRing() {
        expanded.toggle()
        if expanded { hand.isHidden = false }
        UIView.animate(withDuration: 0.16, animations: {
            self.ringLayer.opacity = self.expanded ? 1 : 0
            self.glyphs.forEach { $0.alpha = self.expanded ? 1 : 0 }
            self.hand.alpha = self.expanded ? 1 : 0
        }, completion: { _ in
            if !self.expanded { self.hand.isHidden = true }
        })
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard expanded else { return }
        let p = g.location(in: self)
        guard let i = wedgePaths.firstIndex(where: { $0.contains(p) }) else { return }
        active ^= bits[i]
        refresh()
        onMods?(active)
    }

    @objc private func handTapped() {
        setFingerDraw(!fingerDrawOn)
        onFingerDraw?(fingerDrawOn)
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let sv = superview else { return }
        let t = g.translation(in: sv)
        g.setTranslation(.zero, in: sv)
        var c = CGPoint(x: center.x + t.x, y: center.y + t.y)
        c.x = min(max(c.x, 40), sv.bounds.width - 40)
        c.y = min(max(c.y, 40), sv.bounds.height - 40)
        center = c
        if g.state == .ended {
            UserDefaults.standard.set([Double(c.x / sv.bounds.width), Double(c.y / sv.bounds.height)], forKey: "vcAssistivePos")
        }
    }

    /// Puts the button where it was last left (or at the right edge).
    func restorePosition(in container: UIView) {
        let saved = UserDefaults.standard.array(forKey: "vcAssistivePos") as? [Double]
        let fx = saved?.first ?? 0.93
        let fy = saved?.last ?? 0.55
        center = CGPoint(x: container.bounds.width * CGFloat(fx), y: container.bounds.height * CGFloat(fy))
    }
}

// MARK: - Undo, redo and delete

/// A slim bar with the three buttons a finger needs most.
final class ActionBarView: UIView {
    var onAction: ((String) -> Void)?

    private let actions: [(symbol: String, command: String)] = [
        ("arrow.uturn.backward", "edit.undo"),
        ("arrow.uturn.forward", "edit.redo"),
        ("trash", "edit.clear")
    ]

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 3 * 40 + 8))
        backgroundColor = panelColor
        layer.cornerRadius = 22
        layer.borderWidth = 1
        layer.borderColor = borderColor.cgColor
        for (i, a) in actions.enumerated() {
            let b = UIButton(type: .custom)
            b.frame = CGRect(x: 2, y: 4 + CGFloat(i) * 40, width: 40, height: 40)
            b.setImage(UIImage(systemName: a.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)), for: .normal)
            b.tintColor = .white
            b.tag = i
            b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func tapped(_ b: UIButton) {
        onAction?(actions[b.tag].command)
    }
}
