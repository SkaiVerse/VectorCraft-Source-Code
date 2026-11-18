import UIKit
import UniformTypeIdentifiers
import PhotosUI
import Photos

/// Writes a line to VectorCraft-log.txt (visible in Files: On My iPad > VectorCraft).
func vcLog(_ message: String) {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let url = docs.appendingPathComponent("VectorCraft-log.txt")
    let line = "[swift] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Owns the drawing view and everything that needs Apple's own screens: Files, Photos, alerts,
/// printing, the font picker; and the on-screen buttons (Assistive Touch, undo/redo/delete, the
/// tool arc that opens when the Apple Pencil is squeezed).
final class VectorCraftViewController: UIViewController, UIDocumentPickerDelegate, UIFontPickerViewControllerDelegate, PHPickerViewControllerDelegate {

    private let metal = MetalView()
    private enum Mode { case open, place, save }
    private var mode: Mode = .open

    private let assistive = AssistiveTouchView()
    private let actionBar = ActionBarView()
    private var arcMenu: ArcMenuView?
    private var assistivePlaced = false

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    /// The tools of the arc menu, in the order they sit on it.
    private let arcItems: [ArcMenuView.Item] = [
        .init(title: "Selection", symbol: "cursorarrow", tools: ["selection"]),
        .init(title: "Pen", symbol: "pencil.tip", tools: ["pen"]),
        .init(title: "Shape Builder", symbol: "rectangle.on.rectangle", tools: ["shapeBuilder"]),
        .init(title: "Type", symbol: "textformat", tools: ["type"]),
        .init(title: "Direct Select", symbol: "cursorarrow.rays", tools: ["directSelection"]),
        .init(title: "Eyedropper", symbol: "eyedropper", tools: ["eyedropper", "eyeDropper"]),
        .init(title: "Eraser", symbol: "eraser", tools: ["eraser"]),
        .init(title: "Pencil", symbol: "pencil", tools: ["pencil"])
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)

        metal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metal)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            metal.topAnchor.constraint(equalTo: guide.topAnchor),
            metal.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            metal.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            metal.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
        ])

        metal.onOpenFiles = { [weak self] in self?.pick(.open) }
        metal.onPlaceFiles = { [weak self] in self?.pick(.place) }
        metal.onSave = { [weak self] name, data in self?.handleSave(name: name, data: data) }
        metal.onOpenURL = { url in
            guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return }
            UIApplication.shared.open(u)
        }
        metal.onCopyText = { UIPasteboard.general.string = $0 }
        metal.onPasteText = { UIPasteboard.general.string }
        metal.onPrint = { [weak self] title, data in self?.printPDF(title: title, data: data) }

        // Apple Pencil: squeeze opens the tool arc (and the context menu); double tap goes to the
        // next tool in the same tray.
        metal.onPencilSqueeze = { [weak self] point in
            guard let self = self else { return }
            self.metal.contextClick(at: point)
            self.showArcMenu(at: point)
        }
        metal.onPencilTap = { [weak self] in self?.cycleTray() }
        metal.onFingerDrawChanged = { [weak self] on in self?.assistive.setFingerDraw(on) }

        // On-screen buttons.
        assistive.onMods = { [weak self] bits in self?.metal.stickyMods = bits }
        assistive.onFingerDraw = { [weak self] on in self?.metal.setFingerDraw(on) }
        actionBar.onAction = { [weak self] command in self?.metal.run(command) }
        view.addSubview(actionBar)
        view.addSubview(assistive)
        assistive.isHidden = !(UserDefaults.standard.object(forKey: "vcAssistive") as? Bool ?? true)
        actionBar.isHidden = !(UserDefaults.standard.object(forKey: "vcActionBar") as? Bool ?? true)

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.metal.saveState()
            self?.metal.setFocused(false)
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.metal.setFocused(true)
        }
        nc.addObserver(forName: .vcAddFonts, object: nil, queue: .main) { [weak self] _ in
            self?.showFontPicker()
        }
        nc.addObserver(forName: .vcOpenURL, object: nil, queue: .main) { [weak self] note in
            if let url = note.object as? URL { self?.openHandedOver(url) }
        }
        nc.addObserver(forName: .vcToggleAssistive, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.assistive.isHidden.toggle()
            UserDefaults.standard.set(!self.assistive.isHidden, forKey: "vcAssistive")
        }
        nc.addObserver(forName: .vcToggleActionBar, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.actionBar.isHidden.toggle()
            UserDefaults.standard.set(!self.actionBar.isHidden, forKey: "vcActionBar")
        }
        nc.addObserver(forName: .vcToggleFingerDraw, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.metal.setFingerDraw(!self.metal.fingerDraw)
            self.assistive.setFingerDraw(self.metal.fingerDraw)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        // Beside the toolbar, not over it.
        actionBar.frame.origin = CGPoint(
            x: safe.left + 80,
            y: view.bounds.height - safe.bottom - actionBar.bounds.height - 70
        )
        if !assistivePlaced && view.bounds.width > 100 {
            assistive.restorePosition(in: view)
            assistivePlaced = true
        }
    }

    // MARK: Apple Pencil

    private func pickTool(_ ids: [String]) {
        for id in ids where metal.run("tool.select", "{\"tool\":\"\(id)\"}") { return }
        vcLog("no tool found for \(ids)")
    }

    private func showArcMenu(at point: CGPoint) {
        hideArcMenu()
        let anchor = metal.convert(point, to: view)
        let menu = ArcMenuView(frame: view.bounds, anchor: anchor, items: arcItems)
        menu.onPick = { [weak self] tools in
            self?.pickTool(tools)
            self?.hideArcMenu()
            self?.metal.closeMenus()
        }
        menu.onDismiss = { [weak self] in
            self?.hideArcMenu()
            self?.metal.closeMenus()
        }
        view.insertSubview(menu, belowSubview: assistive)
        arcMenu = menu
    }

    private func hideArcMenu() {
        arcMenu?.removeFromSuperview()
        arcMenu = nil
    }

    /// The tools that share a tray in the toolbar (from the app's own tool list).
    private static let trays: [[String]] = [
        ["directSelection", "groupSelection"],
        ["pen", "addAnchor", "deleteAnchor", "anchorPoint"],
        ["type", "areaType", "typeOnPath", "verticalType", "verticalAreaType", "verticalTypeOnPath", "touchType"],
        ["lineSegment", "arc", "spiral", "rectangularGrid", "polarGrid"],
        ["rectangle", "roundedRectangle", "ellipse", "polygon", "star", "flare"],
        ["paintbrush", "blobBrush"],
        ["shaper", "pencil", "smooth", "pathEraser", "join"],
        ["eraser", "scissors", "knife", "mirrorCut", "lineCut", "rectCut"],
        ["rotate", "reflect"],
        ["scale", "shear", "reshape"],
        ["width", "warp", "twirl", "pucker", "bloat", "scallop", "crystallize", "wrinkle"],
        ["freeTransform", "puppetWarp"],
        ["shapeBuilder", "livePaintBucket", "livePaintSelection"],
        ["perspectiveGrid", "perspectiveSelection"],
        ["eyedropper", "measure"],
        ["blend", "objectsOnPath"],
        ["symbolSprayer", "symbolShifter", "symbolScruncher", "symbolSizer", "symbolSpinner", "symbolStainer", "symbolScreener", "symbolStyler"],
        ["columnGraph", "stackedColumnGraph", "barGraph", "stackedBarGraph", "lineGraph", "areaGraph", "scatterGraph", "pieGraph", "radarGraph"],
        ["artboard", "slice", "sliceSelection"],
        ["hand", "rotateView", "printTiling"]
    ]

    /// Apple Pencil double tap: the next tool in the same tray (Pen: Add Anchor, Delete Anchor,
    /// Anchor Point; Type: Area Type, Type on a Path ...). A tool alone in its tray stays as it is.
    private func cycleTray() {
        let now = metal.currentTool()
        guard let tray = VectorCraftViewController.trays.first(where: { $0.contains(now) }),
              let at = tray.firstIndex(of: now) else {
            vcLog("double tap: \(now) has no other tool in its tray")
            return
        }
        pickTool([tray[(at + 1) % tray.count]])
    }

    // MARK: Fonts

    /// Apple's own font picker: the only way an app can use fonts installed on the iPad.
    private func showFontPicker() {
        guard presentedViewController == nil, view.window?.isKeyWindow ?? true else { return }
        var configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true)
    }

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        metal.suspendFocus = false
        guard let descriptor = viewController.selectedFontDescriptor else { return }
        let stored = SystemFonts.addPicked(descriptor)
        if presentedViewController != nil { dismiss(animated: true) }
        let family = (descriptor.object(forKey: .family) as? String) ?? "the font"
        if stored.isEmpty {
            message("Couldn’t add the font", "iPadOS did not let VectorCraft copy “\(family)”. Some protected fonts can’t be used.")
        } else {
            message("Font added", "Added \(stored.count) style(s) of “\(family)”. Restart VectorCraft once to use \(stored.count == 1 ? "it" : "them").")
        }
    }

    func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
        metal.suspendFocus = false
    }

    // MARK: Opening and placing: Files or Photos

    private func pick(_ m: Mode) {
        vcLog("pick requested: \(m); already presenting: \(presentedViewController != nil)")
        guard presentedViewController == nil else {
            if m == .open { metal.cancelOpen() }
            return
        }
        mode = m
        let sheet = UIAlertController(title: nil, message: m == .place ? "Place from" : "Open from", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Files", style: .default) { [weak self] _ in self?.showFilesPicker() })
        sheet.addAction(UIAlertAction(title: "Photos", style: .default) { [weak self] _ in self?.showPhotoPicker() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.metal.suspendFocus = false
            if m == .open { self?.metal.cancelOpen() }
        })
        centerPopover(sheet)
        metal.suspendFocus = true
        present(sheet, animated: true)
    }

    private func centerPopover(_ sheet: UIAlertController) {
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
    }

    private func showFilesPicker() {
        // A copy of the one chosen file: tapping the file returns it straight away.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        metal.suspendFocus = true
        // The action sheet is still closing: present on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.present(picker, animated: true) { vcLog("files picker is on screen") }
        }
    }

    private func showPhotoPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = (mode == .place) ? 0 : 1
        config.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        metal.suspendFocus = true
        DispatchQueue.main.async { [weak self] in
            self?.present(picker, animated: true) { vcLog("photos picker is on screen") }
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        metal.suspendFocus = false
        let target = mode
        vcLog("photos picker returned \(results.count) item(s) in mode \(target)")
        if results.isEmpty {
            if target == .open { metal.cancelOpen() }
            return
        }
        for r in results {
            let provider = r.itemProvider
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
                if target == .open { metal.cancelOpen() }
                continue
            }
            provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
                var payload: (String, Data)?
                if let url = url, let data = try? Data(contentsOf: url) { payload = (url.lastPathComponent, data) }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let (name, data) = payload {
                        vcLog("photo \(name), \(data.count) bytes")
                        if target == .place { self.metal.deliverPlaced(name: name, data: data) }
                        else { self.metal.deliverOpened(name: name, data: data) }
                    } else {
                        vcLog("photo could not be read: \(error?.localizedDescription ?? "unknown")")
                        if target == .open { self.metal.cancelOpen() }
                        self.message("Couldn’t read the photo", error?.localizedDescription ?? "")
                    }
                }
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        vcLog("picker returned \(urls.count) item(s) in mode \(mode)")
        metal.suspendFocus = false
        switch mode {
        case .open:
            if urls.isEmpty { metal.cancelOpen() }
            for url in urls {
                read(url, onFail: { self.metal.cancelOpen() }) { name, data in self.metal.deliverOpened(name: name, data: data) }
            }
        case .place:
            for url in urls { read(url) { name, data in self.metal.deliverPlaced(name: name, data: data) } }
        case .save:
            if let u = urls.first { vcLog("saved to \(u.lastPathComponent)") }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        vcLog("picker cancelled in mode \(mode)")
        metal.suspendFocus = false
        switch mode {
        case .open:
            metal.cancelOpen()
        case .save:
            message("Not saved", "The file was not saved. VectorCraft may still show it as saved; use Save As to save it again.")
        case .place:
            break
        }
    }

    private func read(_ url: URL, onFail: (() -> Void)? = nil, deliver: (String, Data) -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            vcLog("read \(data.count) bytes from \(url.lastPathComponent)")
            deliver(url.lastPathComponent, data)
        } catch {
            vcLog("read failed: \(error.localizedDescription)")
            onFail?()
            message("Couldn’t open the file", error.localizedDescription)
        }
    }

    /// "Open in VectorCraft" from Files or another app.
    private func openHandedOver(_ url: URL) {
        vcLog("handed over: \(url.lastPathComponent)")
        read(url) { name, data in self.metal.deliverHandedOver(name: name, data: data) }
    }

    // MARK: Saving: Files, and for pictures also Photos

    private func handleSave(name: String, data: Data) {
        vcLog("save sheet requested: \(name), \(data.count) bytes")
        guard presentedViewController == nil else {
            message("Not saved", "Another sheet was open, so “\(name)” was not saved. Try again.")
            return
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp", "webp"].contains(ext) {
            let sheet = UIAlertController(title: nil, message: "Save “\(name)” to", preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Files", style: .default) { [weak self] _ in self?.exportToFiles(name: name, data: data) })
            sheet.addAction(UIAlertAction(title: "Photos", style: .default) { [weak self] _ in self?.saveToPhotos(name: name, data: data) })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.metal.suspendFocus = false
                self?.message("Not saved", "“\(name)” was not saved. VectorCraft may still show it as saved.")
            })
            centerPopover(sheet)
            metal.suspendFocus = true
            present(sheet, animated: true)
        } else {
            exportToFiles(name: name, data: data)
        }
    }

    private func exportToFiles(name: String, data: Data) {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(safe)
            try data.write(to: file)
            mode = .save
            let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
            picker.delegate = self
            metal.suspendFocus = true
            DispatchQueue.main.async { [weak self] in self?.present(picker, animated: true) }
        } catch {
            metal.suspendFocus = false
            message("Couldn’t prepare the file", error.localizedDescription)
        }
    }

    private func saveToPhotos(name: String, data: Data) {
        metal.suspendFocus = false
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard status == .authorized || status == .limited else {
                    self.message("Couldn’t save to Photos", "Allow VectorCraft to add photos in Settings › Privacy & Security › Photos.")
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = name
                    request.addResource(with: .photo, data: data, options: options)
                }, completionHandler: { ok, error in
                    DispatchQueue.main.async {
                        vcLog("save to Photos: \(ok) \(error?.localizedDescription ?? "")")
                        self.message(ok ? "Saved to Photos" : "Couldn’t save to Photos", ok ? name : (error?.localizedDescription ?? ""))
                    }
                })
            }
        }
    }

    // MARK: Printing and messages

    private func printPDF(title: String, data: Data) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = title
        controller.printInfo = info
        controller.printingItem = data
        controller.present(from: metal.bounds, in: metal, animated: true, completionHandler: nil)
    }

    /// Shown a moment later, so it still appears while a picker is closing.
    private func message(_ title: String, _ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            let a = UIAlertController(title: title, message: text, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(a, animated: true)
        }
    }
}
