import UIKit
import UniformTypeIdentifiers

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

/// Owns the drawing view and everything that needs Apple's own screens: Files, alerts, printing,
/// the font picker.
///
/// Saving: VectorCraft hands over a finished file and this class shows Apple's Save to Files
/// sheet. Opening gives the app a copy of the chosen file, so nothing is ever changed behind the
/// person's back and no duplicates are made.
final class VectorCraftViewController: UIViewController, UIDocumentPickerDelegate, UIFontPickerViewControllerDelegate {

    private let metal = MetalView()
    private enum Mode { case open, place, save }
    private var mode: Mode = .open

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

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

    // MARK: Opening and placing files

    private func pick(_ m: Mode) {
        vcLog("pick requested: \(m); already presenting: \(presentedViewController != nil)")
        guard presentedViewController == nil else {
            if m == .open { metal.cancelOpen() }
            return
        }
        mode = m
        // A copy of the one chosen file: tapping the file returns it straight away.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true) { vcLog("picker is on screen") }
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

    // MARK: Saving

    /// Apple's own Save to Files sheet (Save, Save As, or an export).
    private func handleSave(name: String, data: Data) {
        vcLog("save sheet requested: \(name), \(data.count) bytes")
        guard presentedViewController == nil else {
            message("Not saved", "Another sheet was open, so “\(name)” was not saved. Try again.")
            return
        }
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
            present(picker, animated: true)
        } catch {
            metal.suspendFocus = false
            message("Couldn’t prepare the file", error.localizedDescription)
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
