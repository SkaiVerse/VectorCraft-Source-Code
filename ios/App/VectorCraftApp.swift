import SwiftUI

extension Notification.Name {
    static let vcAddFonts = Notification.Name("VectorCraftAddFonts")
    static let vcOpenURL = Notification.Name("VectorCraftOpenURL")
}

@main
struct VectorCraftApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()
                VectorCraftHost()
            }
            .statusBarHidden(true)
            // "Open in VectorCraft" from Files or another app.
            .onOpenURL { url in
                NotificationCenter.default.post(name: .vcOpenURL, object: url)
            }
        }
        .commands {
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
