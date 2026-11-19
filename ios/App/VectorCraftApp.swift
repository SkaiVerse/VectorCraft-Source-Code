import SwiftUI

extension Notification.Name {
    static let vcAddFonts = Notification.Name("VectorCraftAddFonts")
    static let vcOpenURL = Notification.Name("VectorCraftOpenURL")
    static let vcToggleAssistive = Notification.Name("VectorCraftToggleAssistive")
    static let vcToggleActionBar = Notification.Name("VectorCraftToggleActionBar")
    static let vcToggleFingerDraw = Notification.Name("VectorCraftToggleFingerDraw")
}

@main
struct VectorCraftApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()
                VectorCraftHost()
                    // The on-screen keyboard floats over the app; it never resizes or shifts it.
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .statusBarHidden(true)
            // "Open in VectorCraft" from Files or another app.
            .onOpenURL { url in
                NotificationCenter.default.post(name: .vcOpenURL, object: url)
            }
        }
        .commands {
            CommandMenu("Touch") {
                Button("Show or Hide Assistive Touch") {
                    NotificationCenter.default.post(name: .vcToggleAssistive, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .option, .shift])
                Button("Show or Hide Undo, Redo and Delete Buttons") {
                    NotificationCenter.default.post(name: .vcToggleActionBar, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .option, .shift])
                Button("Draw With Finger On or Off") {
                    NotificationCenter.default.post(name: .vcToggleFingerDraw, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .option, .shift])
            }
            CommandMenu("Fonts") {
                Button("Add Installed Fonts…") {
                    NotificationCenter.default.post(name: .vcAddFonts, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
            }
        }
    }
}

struct VectorCraftHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> VectorCraftViewController { VectorCraftViewController() }
    func updateUIViewController(_ vc: VectorCraftViewController, context: Context) {}
}
