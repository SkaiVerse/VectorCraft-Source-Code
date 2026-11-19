import UIKit
import QuartzCore

/// The drawing surface. Catches the pointer, fingers, Apple Pencil, scrolling, pinching and the
/// keyboard, and hands them to the Rust core.
final class MetalView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIPencilInteractionDelegate, UIPointerInteractionDelegate {

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // Hooks the view controller fills in.
    var onOpenFiles: (() -> Void)?
    var onPlaceFiles: (() -> Void)?
    var onSave: ((String, Data) -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onCopyText: ((String) -> Void)?
    var onPasteText: (() -> String?)?
    var onPrint: ((String, Data) -> Void)?
    var onPencilTap: (() -> Void)?
    var onPencilSqueeze: ((CGPoint) -> Void)?
    var onFingerDrawChanged: ((Bool) -> Void)?
    /// The twist in degrees while a selection is being turned (nil: the gesture is over).
    var onTwist: ((Double?) -> Void)?
    /// Modifier keys held down on screen (Assistive Touch): added to every real one.
    var stickyMods: UInt32 = 0 {
        didSet { if let h = handle { vc_mods(h, stickyMods) } }
    }
    private(set) var fingerDraw = false
    /// Where the pencil (or the pointer) last was.
    private(set) var lastPoint = CGPoint(x: 200, y: 200)
    /// A touch wider than this (points) is a resting palm, not a fingertip.
    private let palmRadius: CGFloat = 42
    private var ignoredTouches = Set<ObjectIdentifier>()
    private var twistLast = 0.0
    private var twistTotal = 0.0
    private var twistActive = false
    private var twistTurnsSelection = false
    private var twistApplied = false
    private var twistShown = 0.0
    /// True while a picker or alert is showing, so the view doesn't grab the keyboard back.
    var suspendFocus = false

    /// Pencil tilt and barrel roll are read but not sent yet: their directions need testing.
    private let sendPenPose = false

    private var handle: UnsafeMutableRawPointer?
    private var startFailed = false
    private var link: CADisplayLink?
    private var softKeyboard = false
    private let emptyInput = UIView(frame: .zero)
    private var scratch: UnsafeMutablePointer<CChar>?
    private var pointerButton: Int32 = 0
    private var held: (hid: UInt32, mods: UInt32, text: String?, start: CFTimeInterval, last: CFTimeInterval)?

    /// Small numbers for the touches in progress (what the app follows a finger or the pen by).
    private var touchIDs: [ObjectIdentifier: Int32] = [:]
    private var nextTouchID: Int32 = 1
    private var fingersDown = 0

    // UITextInputTraits (no autocorrect while typing into text)
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        setupGestures()
        addInteraction(UIPointerInteraction(delegate: self))
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MetalView, _) in
            view.pushTheme()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        link?.invalidate()
        if let h = handle { vc_destroy(h) }
        if let s = scratch { free(s) }
    }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            ensureHandle()
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(tick))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
                l.add(to: .main, forMode: .common)
                link = l
            }
        } else {
            link?.invalidate()
            link = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ensureHandle()
        if let h = handle {
            let s = traitCollection.displayScale
            vc_resize(h, UInt32(max(1, bounds.width * s)), UInt32(max(1, bounds.height * s)), Float(s))
        }
    }

    private func ensureHandle() {
        guard handle == nil, !startFailed, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        let s = traitCollection.displayScale
        contentScaleFactor = s
        metalLayer.contentsScale = s
        let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()
        handle = vc_create(layerPtr, UInt32(bounds.width * s), UInt32(bounds.height * s), Float(s), makeCallbacks())
        if let h = handle {
            pushTheme()
        } else {
            startFailed = true
        }
    }

    private func pushTheme() {
        guard let h = handle else { return }
        vc_set_dark(h, traitCollection.userInterfaceStyle == .dark ? 1 : 0)
    }

    func saveState() { if let h = handle { vc_save_state(h) } }
    func setFocused(_ focused: Bool) { if let h = handle { vc_set_focused(h, focused ? 1 : 0) } }

    @objc private func tick() {
        guard let h = handle else { return }
        if !suspendFocus && !isFirstResponder { _ = becomeFirstResponder() }
        repeatHeldKey()
        let flags = vc_frame(h)
        let fd = (flags & 4) != 0
        if fd != fingerDraw {
            fingerDraw = fd
            onFingerDrawChanged?(fd)
        }
        let wants = (flags & 2) != 0
        if wants != softKeyboard {
            softKeyboard = wants
            reloadInputViews()
        }
    }

    // MARK: Callbacks from Rust

    fileprivate static func from(_ p: UnsafeMutableRawPointer?) -> MetalView? {
        p.map { Unmanaged<MetalView>.fromOpaque($0).takeUnretainedValue() }
    }

    fileprivate func stash(_ s: String?) -> UnsafePointer<CChar>? {
        if let old = scratch { free(old) }
        scratch = s.flatMap { strdup($0) }
        return scratch.map { UnsafePointer($0) }
    }

    private func makeCallbacks() -> VCCallbacks {
        let me = Unmanaged.passUnretained(self).toOpaque()
        return VCCallbacks(
            user: me,
            open_files: { u in MetalView.from(u)?.onOpenFiles?() },
            place_files: { u in MetalView.from(u)?.onPlaceFiles?() },
            save_file: { u, name, data, len in
                guard let v = MetalView.from(u), let name = name else { return }
                let bytes = (data != nil && len > 0) ? Data(bytes: data!, count: len) : Data()
                v.onSave?(String(cString: name), bytes)
            },
            open_url: { u, url in
                guard let v = MetalView.from(u), let url = url else { return }
                v.onOpenURL?(String(cString: url))
            },
            copy_text: { u, text in
                guard let v = MetalView.from(u), let text = text else { return }
                v.onCopyText?(String(cString: text))
            },
            paste_text: { u in
                guard let v = MetalView.from(u) else { return nil }
                return v.stash(v.onPasteText?())
            },
            print_pdf: { u, title, data, len in
                guard let v = MetalView.from(u), let data = data else { return }
                let name = title.map { String(cString: $0) } ?? "VectorCraft"
                v.onPrint?(name, Data(bytes: data, count: len))
            }
        )
    }

    // MARK: Results from the view controller

    private func deliver(_ name: String, _ data: Data, _ send: (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<UInt8>?, Int) -> Void) {
        guard let h = handle else { return }
        name.withCString { n in
            data.withUnsafeBytes { raw in
                send(h, n, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        }
    }

    func deliverOpened(name: String, data: Data) { deliver(name, data) { vc_open_file($0, $1, $2, $3) } }
    func deliverPlaced(name: String, data: Data) { deliver(name, data) { vc_place_file($0, $1, $2, $3) } }
    func deliverHandedOver(name: String, data: Data) { deliver(name, data) { vc_drop_file($0, $1, $2, $3) } }
    func cancelOpen() { if let h = handle { vc_open_cancel(h) } }

    // MARK: Apple Pencil double tap and squeeze

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        onPencilTap?()
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        let p = squeeze.hoverPose?.location ?? lastPoint
        onPencilSqueeze?(p)
    }

    // The mouse pointer is hidden: VectorCraft draws its own tool cursors.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle.hidden()
    }

    // MARK: Commands for the on-screen buttons

    func setFingerDraw(_ on: Bool) {
        fingerDraw = on
        if let h = handle { vc_set_finger_draw(h, on ? 1 : 0) }
    }

    @discardableResult
    func run(_ command: String, _ json: String = "{}") -> Bool {
        guard let h = handle else { return false }
        return vc_run(h, command, json) == 0
    }

    /// Escape: closes an open menu.
    func closeMenus() {
        guard let h = handle else { return }
        vc_key(h, 0x29, 1, 0, 0)
        vc_key(h, 0x29, 0, 0, 0)
    }

    /// One of the app's own colours, so what is drawn over it follows its theme.
    /// 0 panel, 1 window (menus), 2 text, 3 accent.
    func themeColor(_ which: Int32) -> UIColor {
        guard let h = handle else { return UIColor(white: 0.15, alpha: 1) }
        let v = vc_theme_color(h, which)
        return UIColor(red: CGFloat((v >> 24) & 255) / 255, green: CGFloat((v >> 16) & 255) / 255,
                       blue: CGFloat((v >> 8) & 255) / 255, alpha: CGFloat(v & 255) / 255)
    }

    func currentTool() -> String {
        guard let h = handle, let c = vc_tool_id(h) else { return "" }
        return String(cString: c)
    }

    /// A secondary click (the context menu) at a point.
    func contextClick(at p: CGPoint) {
        guard let h = handle else { return }
        vc_pointer_moved(h, Float(p.x), Float(p.y), stickyMods)
        vc_pointer_button(h, Float(p.x), Float(p.y), 1, 1, stickyMods)
        vc_pointer_button(h, Float(p.x), Float(p.y), 1, 0, stickyMods)
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { softKeyboard ? nil : emptyInput }

    override func resignFirstResponder() -> Bool {
        held = nil
        return super.resignFirstResponder()
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard let h = handle else { return }
        if text == "\n" {
            vc_key(h, 0x28, 1, 0, 0)
            vc_key(h, 0x28, 0, 0, 0)
        } else {
            text.withCString { vc_text(h, $0) }
        }
    }

    func deleteBackward() {
        guard let h = handle else { return }
        vc_key(h, 0x2A, 1, 0, 0)
        vc_key(h, 0x2A, 0, 0, 0)
    }

    private func modBits(_ f: UIKeyModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.shift) { m |= 1 }
        if f.contains(.control) { m |= 2 }
        if f.contains(.alternate) { m |= 4 }
        if f.contains(.command) { m |= 8 }
        return m | stickyMods
    }

    /// Only real typing keys type text: letters, digits, punctuation, space and the keypad.
    /// Arrows, Return, Tab, Escape, F-keys and the like are key presses, never text.
    private func typesText(_ hid: UInt32) -> Bool {
        if hid >= 0x04 && hid <= 0x27 { return true }                 // letters and digits
        if hid >= 0x2C && hid <= 0x38 { return true }                 // space and punctuation
        if hid >= 0x54 && hid <= 0x63 && hid != 0x58 { return true }  // keypad (not its Enter)
        return false
    }

    private func printable(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        let ok = s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
        return ok ? s : nil
    }

    /// ⌘C, ⌘X and ⌘V go through the iPad's clipboard.
    private func clipboardShortcut(hid: UInt32, mods: UInt32) -> Bool {
        guard mods == 8, let h = handle else { return false }
        switch hid {
        case 0x06: vc_copy(h); return true
        case 0x1B: vc_cut(h); return true
        case 0x19:
            if let s = UIPasteboard.general.string, !s.isEmpty { s.withCString { vc_paste(h, $0) } }
            return true
        default: return false
        }
    }

    private func handlePress(_ press: UIPress, down: Bool) -> Bool {
        guard let key = press.key, let h = handle else { return false }
        let hid = UInt32(key.keyCode.rawValue)
        if hid >= 0xE0 && hid <= 0xE7 { return true }   // a modifier key on its own
        let mods = modBits(key.modifierFlags)
        if down {
            if clipboardShortcut(hid: hid, mods: mods) { return true }
            vc_key(h, hid, 1, 0, mods)
            var text: String? = nil
            if typesText(hid) && mods & (8 | 2) == 0 { text = printable(key.characters) }
            if let t = text { t.withCString { vc_text(h, $0) } }
            let now = CACurrentMediaTime()
            held = (hid, mods, text, now, now)
        } else {
            vc_key(h, hid, 0, 0, mods)
            if held?.hid == hid { held = nil }
        }
        return true
    }

    private func repeatHeldKey() {
        guard let k = held, let h = handle else { return }
        let now = CACurrentMediaTime()
        if now - k.start > 0.4 && now - k.last > 0.035 {
            vc_key(h, k.hid, 1, 1, k.mods)
            if let t = k.text { t.withCString { vc_text(h, $0) } }
            held?.last = now
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses where !handlePress(p, down: true) { rest.insert(p) }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses where !handlePress(p, down: false) { rest.insert(p) }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        held = nil
        super.pressesCancelled(presses, with: event)
    }

    // ⌘ shortcuts are claimed ahead of the system so ⌘Z, ⌘S, ⌘F and friends reach the app.
    private static let commandKeys: [UIKeyCommand] = {
        let letters = Array("abcdefgijklmnoprstuvxyz0123456789-=[];',./\\`").map { String($0) }
        let specials = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
                        UIKeyCommand.inputRightArrow, UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown,
                        UIKeyCommand.inputHome, UIKeyCommand.inputEnd]
        let mods: [UIKeyModifierFlags] = [.command, [.command, .shift], [.command, .alternate], [.command, .shift, .alternate]]
        var list: [UIKeyCommand] = []
        for input in letters + specials {
            for m in mods {
                let c = UIKeyCommand(input: input, modifierFlags: m, action: #selector(MetalView.commandKey(_:)))
                c.wantsPriorityOverSystemBehavior = true
                list.append(c)
            }
        }
        return list
    }()

    override var keyCommands: [UIKeyCommand]? { MetalView.commandKeys }

    private static func hid(for s: String) -> UInt32? {
        switch s {
        case UIKeyCommand.inputUpArrow: return 0x52
        case UIKeyCommand.inputDownArrow: return 0x51
        case UIKeyCommand.inputLeftArrow: return 0x50
        case UIKeyCommand.inputRightArrow: return 0x4F
        case UIKeyCommand.inputPageUp: return 0x4B
        case UIKeyCommand.inputPageDown: return 0x4E
        case UIKeyCommand.inputHome: return 0x4A
        case UIKeyCommand.inputEnd: return 0x4D
        default: break
        }
        guard s.unicodeScalars.count == 1, let u = s.lowercased().unicodeScalars.first else { return nil }
        switch u {
        case "a"..."z": return 0x04 + (u.value - 97)
        case "1"..."9": return 0x1E + (u.value - 49)
        case "0": return 0x27
        case "-": return 0x2D
        case "=": return 0x2E
        case "[": return 0x2F
        case "]": return 0x30
        case "\\": return 0x31
        case ";": return 0x33
        case "'": return 0x34
        case "`": return 0x35
        case ",": return 0x36
        case ".": return 0x37
        case "/": return 0x38
        default: return nil
        }
    }

    @objc func commandKey(_ cmd: UIKeyCommand) {
        guard let h = handle, let input = cmd.input, let hid = MetalView.hid(for: input) else { return }
        let mods = modBits(cmd.modifierFlags)
        if clipboardShortcut(hid: hid, mods: mods) { return }
        vc_key(h, hid, 1, 0, mods)
        vc_key(h, hid, 0, 0, mods)
    }

    // MARK: Pointer, fingers, Apple Pencil, scrolling

    private func setupGestures() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverMoved(_:)))
        addGestureRecognizer(hover)

        // Mouse wheel and trackpad scrolling.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(pointerScroll(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        wheel.cancelsTouchesInView = false
        wheel.delegate = self
        addGestureRecognizer(wheel)

        // Two fingers twisting: the selection turns with them, or the canvas when nothing is
        // selected. (The fingers also reach the app as touches, which pan and zoom.)
        let twist = UIRotationGestureRecognizer(target: self, action: #selector(twisted(_:)))
        twist.cancelsTouchesInView = false
        twist.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twist.delegate = self
        addGestureRecognizer(twist)

        // Trackpad pinch. Finger pinches reach the app as touches, which it zooms with itself.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func hoverMoved(_ g: UIHoverGestureRecognizer) {
        guard let h = handle else { return }
        switch g.state {
        case .began, .changed:
            let p = g.location(in: self)
            lastPoint = p
            vc_pointer_moved(h, Float(p.x), Float(p.y), modBits(g.modifierFlags))
        case .ended, .cancelled:
            vc_pointer_gone(h)
        default: break
        }
    }

    @objc private func pointerScroll(_ g: UIPanGestureRecognizer) {
        guard let h = handle, g.state != .ended, g.state != .cancelled, g.state != .failed else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if t != .zero { vc_scroll(h, Float(t.x), Float(t.y), modBits(g.modifierFlags)) }
    }

    @objc private func twisted(_ g: UIRotationGestureRecognizer) {
        guard let h = handle else { return }
        let degrees = Double(g.rotation) * 180 / Double.pi
        switch g.state {
        case .began:
            twistActive = false
            twistApplied = false
            twistTotal = 0
            twistLast = 0
            twistShown = 0
            twistTurnsSelection = vc_has_selection(h) != 0
        case .changed:
            // Only a clear twist counts: a pinch or a pan wobbles a few degrees.
            if !twistActive {
                guard abs(degrees) > 25, fingersDown == 2 else { return }
                twistActive = true
                twistLast = degrees
            }
            let delta = degrees - twistLast
            twistLast = degrees
            twistTotal += delta
            if twistTurnsSelection {
                // A live preview: the selection is turned to the twist so far, each time in place
                // of the last turn, so the undo history ends up with one step.
                guard abs(twistTotal - twistShown) >= 0.5 else { return }
                if twistApplied { run("edit.undo") }
                // The app turns anticlockwise for a positive angle; a clockwise twist is negative.
                twistApplied = run("object.rotate", "{\"angle\": \(-twistTotal)}")
                twistShown = twistTotal
                onTwist?(twistTotal)
            } else {
                // Clockwise on screen, as the finger twist.
                run("view.rotate", "{\"angle\": \(delta)}")
            }
        case .ended:
            onTwist?(nil)
            twistActive = false
            twistApplied = false
        default:
            // The gesture was interrupted: the preview is taken back.
            if twistApplied { run("edit.undo") }
            onTwist?(nil)
            twistActive = false
            twistApplied = false
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard let h = handle, g.state == .changed, fingersDown == 0 else { return }
        vc_pinch(h, Float(g.scale))
        g.scale = 1
    }

    private func touchID(_ t: UITouch) -> Int32 {
        let key = ObjectIdentifier(t)
        if let id = touchIDs[key] { return id }
        let id = nextTouchID
        nextTouchID = nextTouchID >= Int32.max - 1 ? 1 : nextTouchID + 1
        touchIDs[key] = id
        return id
    }

    /// One finger or Apple Pencil contact, for the app to follow.
    private func send(_ t: UITouch, phase: Int32, at touch: UITouch? = nil, event: UIEvent?) {
        guard let h = handle else { return }
        let s = touch ?? t
        let p = s.location(in: self)
        if t.type == .pencil { lastPoint = p }
        let mods = modBits(event?.modifierFlags ?? [])
        let id = touchID(t)
        if t.type == .pencil {
            var pressure: Float = 0
            if phase != 2 && phase != 3 {
                let m = s.maximumPossibleForce
                pressure = m > 0 ? Float(min(max(s.force / m, 0), 1)) : 1
            }
            var tiltX = Float.nan, tiltY = Float.nan, roll = Float.nan
            if sendPenPose {
                let lean = (Double.pi / 2 - Double(s.altitudeAngle)) * 180 / Double.pi
                let v = s.azimuthUnitVector(in: self)
                // First guess: the barrel leans away from where the tip points.
                tiltX = Float(-Double(v.dx) * lean)
                tiltY = Float(-Double(v.dy) * lean)
                roll = Float(Double(s.rollAngle) * 180 / Double.pi)
            }
            vc_touch(h, 1, id, phase, Float(p.x), Float(p.y), pressure, mods, tiltX, tiltY, roll)
        } else {
            vc_touch(h, 0, id, phase, Float(p.x), Float(p.y), 0, mods, Float.nan, Float.nan, Float.nan)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let h = handle else { return }
        let mods = modBits(event?.modifierFlags ?? [])
        for t in touches {
            let p = t.location(in: self)
            switch t.type {
            case .indirectPointer:
                pointerButton = (event?.buttonMask.contains(.secondary) ?? false) ? 1 : 0
                vc_pointer_moved(h, Float(p.x), Float(p.y), mods)
                vc_pointer_button(h, Float(p.x), Float(p.y), pointerButton, 1, mods)
            case .pencil:
                send(t, phase: 0, event: event)
            case .direct:
                // A palm is much wider than a fingertip: ignore it.
                if t.majorRadius > palmRadius {
                    ignoredTouches.insert(ObjectIdentifier(t))
                    continue
                }
                fingersDown += 1
                send(t, phase: 0, event: event)
            default:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let h = handle else { return }
        let mods = modBits(event?.modifierFlags ?? [])
        for t in touches {
            switch t.type {
            case .indirectPointer:
                let p = t.location(in: self)
                vc_pointer_moved(h, Float(p.x), Float(p.y), mods)
            case .pencil:
                // Every position the pencil reported since the last frame (up to 240 a second),
                // so quick strokes keep their curve.
                let samples = event?.coalescedTouches(for: t) ?? [t]
                for c in samples { send(t, phase: 1, at: c, event: event) }
            case .direct:
                if ignoredTouches.contains(ObjectIdentifier(t)) { continue }
                send(t, phase: 1, event: event)
            default:
                break
            }
        }
    }

    private func finish(_ touches: Set<UITouch>, with event: UIEvent?, cancelled: Bool) {
        guard let h = handle else { return }
        let mods = modBits(event?.modifierFlags ?? [])
        for t in touches {
            switch t.type {
            case .indirectPointer:
                let p = t.location(in: self)
                vc_pointer_button(h, Float(p.x), Float(p.y), pointerButton, 0, mods)
            case .pencil:
                send(t, phase: cancelled ? 3 : 2, event: event)
                touchIDs[ObjectIdentifier(t)] = nil
            case .direct:
                if ignoredTouches.remove(ObjectIdentifier(t)) != nil { continue }
                fingersDown = max(0, fingersDown - 1)
                send(t, phase: cancelled ? 3 : 2, event: event)
                touchIDs[ObjectIdentifier(t)] = nil
            default:
                break
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, with: event, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, with: event, cancelled: true) }
}
