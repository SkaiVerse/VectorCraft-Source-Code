import UIKit

private let panelColor = UIColor(white: 0.13, alpha: 0.94)
private let borderColor = UIColor(white: 1, alpha: 0.18)

private func styled(_ b: UIButton, size: CGFloat) {
    b.backgroundColor = panelColor
    b.layer.cornerRadius = size / 2
    b.layer.borderWidth = 1
    b.layer.borderColor = borderColor.cgColor
    b.tintColor = .white
    b.setTitleColor(.white, for: .normal)
}

// MARK: - Arc tool menu (Apple Pencil squeeze)

/// A strip of tools curving round the point where the pencil was squeezed.
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
        let radius: CGFloat = 170
        let above = anchor.y > 260
        let from: CGFloat = above ? CGFloat.pi + 0.32 : 0.32
        let to: CGFloat = above ? 2 * CGFloat.pi - 0.32 : CGFloat.pi - 0.32

        // The strip behind the buttons.
        let strip = CAShapeLayer()
        strip.path = UIBezierPath(arcCenter: anchor, radius: radius, startAngle: from - 0.12, endAngle: to + 0.12, clockwise: true).cgPath
        strip.strokeColor = UIColor(white: 0.1, alpha: 0.88).cgColor
        strip.fillColor = UIColor.clear.cgColor
        strip.lineWidth = 92
        strip.lineCap = .round
        layer.addSublayer(strip)

        let count = items.count
        for (i, item) in items.enumerated() {
            let t = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 0.5
            let angle = from + (to - from) * t
            var c = CGPoint(x: anchor.x + radius * cos(angle), y: anchor.y + radius * sin(angle))
            c.x = min(max(c.x, 48), bounds.width - 48)
            c.y = min(max(c.y, 48), bounds.height - 48)

            var config = UIButton.Configuration.filled()
            config.image = UIImage(systemName: item.symbol)
            config.title = item.title
            config.imagePlacement = .top
            config.imagePadding = 3
            config.baseBackgroundColor = UIColor(white: 0.25, alpha: 1)
            config.baseForegroundColor = .white
            config.cornerStyle = .large
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = UIFont.systemFont(ofSize: 10, weight: .medium)
                return a
            }
            let b = UIButton(configuration: config)
            b.frame = CGRect(x: 0, y: 0, width: 72, height: 66)
            b.center = c
            b.tag = i
            b.addTarget(self, action: #selector(picked(_:)), for: .touchUpInside)
            addSubview(b)
        }
    }

    @objc private func picked(_ b: UIButton) {
        onPick?(items[b.tag].tools)
    }

    // A tap anywhere else closes the menu.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onDismiss?()
    }
}

// MARK: - Assistive Touch (modifier keys on screen)

/// A round button you can drag anywhere. Tap it to open a ring of Shift, Control, Option and
/// Command; each one latches (several at once), as on a keyboard. A hand button switches
/// "draw with finger" on and off.
final class AssistiveTouchView: UIView {
    var onMods: ((UInt32) -> Void)?
    var onFingerDraw: ((Bool) -> Void)?

    private let main = UIButton(type: .custom)
    private let hand = UIButton(type: .custom)
    private var keyButtons: [UIButton] = []
    private let keyBits: [UInt32] = [1, 2, 8, 4]
    private let keyGlyphs = ["⇧", "⌃", "⌘", "⌥"]
    private let keyOffsets: [CGPoint] = [CGPoint(x: 0, y: -72), CGPoint(x: -72, y: 0), CGPoint(x: 72, y: 0), CGPoint(x: 0, y: 72)]
    private var expanded = false
    private var active: UInt32 = 0
    private(set) var fingerDrawOn = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 230, height: 230))
        backgroundColor = .clear

        main.frame = CGRect(x: 0, y: 0, width: 58, height: 58)
        main.center = CGPoint(x: bounds.midX, y: bounds.midY)
        styled(main, size: 58)
        main.backgroundColor = UIColor(white: 0.35, alpha: 0.92)
        main.layer.borderWidth = 5
        main.layer.borderColor = UIColor(white: 0.85, alpha: 0.9).cgColor
        main.addTarget(self, action: #selector(toggleRing), for: .touchUpInside)
        main.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))

        for (i, glyph) in keyGlyphs.enumerated() {
            let b = UIButton(type: .custom)
            b.frame = CGRect(x: 0, y: 0, width: 54, height: 54)
            b.center = CGPoint(x: bounds.midX + keyOffsets[i].x, y: bounds.midY + keyOffsets[i].y)
            styled(b, size: 54)
            b.setTitle(glyph, for: .normal)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 26, weight: .semibold)
            b.tag = i
            b.alpha = 0
            b.isHidden = true
            b.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
            addSubview(b)
            keyButtons.append(b)
        }

        hand.frame = CGRect(x: 0, y: 0, width: 54, height: 54)
        hand.center = CGPoint(x: bounds.midX + 64, y: bounds.midY - 64)
        styled(hand, size: 54)
        hand.setImage(UIImage(systemName: "hand.point.up.left.fill"), for: .normal)
        hand.alpha = 0
        hand.isHidden = true
        hand.addTarget(self, action: #selector(handTapped), for: .touchUpInside)
        addSubview(hand)

        addSubview(main)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Only the buttons take touches; the rest of the square lets them through to the canvas.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for v in subviews.reversed() where !v.isHidden && v.alpha > 0.05 {
            let p = v.convert(point, from: self)
            if v.point(inside: p, with: event) { return v.hitTest(p, with: event) ?? v }
        }
        return nil
    }

    func setFingerDraw(_ on: Bool) {
        fingerDrawOn = on
        hand.backgroundColor = on ? UIColor.systemBlue : panelColor
    }

    /// Releases every latched key (after a gesture used them).
    func clearKeys() {
        active = 0
        refresh()
        onMods?(0)
    }

    private func refresh() {
        for (i, b) in keyButtons.enumerated() {
            b.backgroundColor = (active & keyBits[i]) != 0 ? UIColor.systemBlue : panelColor
        }
        main.backgroundColor = active != 0 ? UIColor.systemBlue.withAlphaComponent(0.8) : UIColor(white: 0.35, alpha: 0.92)
    }

    @objc private func toggleRing() {
        expanded.toggle()
        let shown = keyButtons + [hand]
        if expanded { shown.forEach { $0.isHidden = false } }
        UIView.animate(withDuration: 0.18, animations: {
            shown.forEach { $0.alpha = self.expanded ? 1 : 0 }
        }, completion: { _ in
            if !self.expanded { shown.forEach { $0.isHidden = true } }
        })
    }

    @objc private func keyTapped(_ b: UIButton) {
        active ^= keyBits[b.tag]
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
        let fx = saved?.first ?? 0.94
        let fy = saved?.last ?? 0.55
        center = CGPoint(x: container.bounds.width * CGFloat(fx), y: container.bounds.height * CGFloat(fy))
    }
}

// MARK: - Undo, redo and delete

/// A slim bar of the three buttons a finger needs most.
final class ActionBarView: UIView {
    var onAction: ((String) -> Void)?

    private let actions: [(symbol: String, command: String)] = [
        ("arrow.uturn.backward", "edit.undo"),
        ("arrow.uturn.forward", "edit.redo"),
        ("trash", "edit.clear")
    ]

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 60, height: 3 * 56 + 16))
        backgroundColor = panelColor
        layer.cornerRadius = 30
        layer.borderWidth = 1
        layer.borderColor = borderColor.cgColor
        for (i, a) in actions.enumerated() {
            let b = UIButton(type: .custom)
            b.frame = CGRect(x: 4, y: 8 + CGFloat(i) * 56, width: 52, height: 52)
            b.setImage(UIImage(systemName: a.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)), for: .normal)
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
