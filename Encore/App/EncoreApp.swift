import SwiftUI

@main
struct EncoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// One model for the process: SwiftUI may build this struct more than once.
    private let app = AppModel.shared

    var body: some Scene {
        Window("Encore", id: "main") {
            RootView()
                .environment(app)
                .tint(.encore)
        }
        .defaultSize(width: 1280, height: 820)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { EncoreCommands(app: app) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { AppModel.shared.engine.start() }
    }

    /// Closing the window keeps the music going; Encore stays in the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock click brings the window back. AppKit's own check would see the
    /// hidden player window as "visible" and do nothing, so this always decides.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showMainWindow()
        return false
    }

    /// Right-click on the Dock icon: what is playing, and the transport.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let p = AppModel.shared.player
        let menu = NSMenu()
        if let t = p.current {
            let title = NSMenuItem(title: "\(t.title) — \(t.artistLine)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        menu.addItem(DockItem(p.isPlaying ? "Pause" : "Play") { p.toggle() })
        menu.addItem(DockItem("Next") { p.next() })
        menu.addItem(DockItem("Previous") { p.previous() })
        if p.current != nil {
            menu.addItem(DockItem(p.liked == true ? "Unlike" : "Like") { p.toggleLike() })
        }
        return menu
    }
}

/// Dock-menu items that run closures (one shared target).
private final class DockActions: NSObject {
    static let shared = DockActions()
    final class Run: NSObject { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f } }
    @objc func fire(_ sender: NSMenuItem) { (sender.representedObject as? Run)?.f() }
}

private func DockItem(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(DockActions.fire(_:)), keyEquivalent: "")
    item.target = DockActions.shared
    item.representedObject = DockActions.Run(run)
    return item
}

extension Color {
    static let encore = Color(red: 1.0, green: 0.27, blue: 0.36)
}

struct EncoreCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Controls") {
            Button(app.player.isPlaying ? "Pause" : "Play") { app.player.toggle() }
            Button("Next  ⌘→") { app.player.next() }
            Button("Previous  ⌘←") { app.player.previous() }
            Divider()
            Button("Volume Up  ⌘↑") { app.player.volume = min(1, app.player.volume + 0.1) }
            Button("Volume Down  ⌘↓") { app.player.volume = max(0, app.player.volume - 0.1) }
            Divider()
            Button("Shuffle") { app.player.toggleShuffle() }.keyboardShortcut("s", modifiers: [.command, .option])
            Button("Repeat") { app.player.cycleRepeat() }.keyboardShortcut("r", modifiers: [.command, .option])
            Button("Like") { app.player.toggleLike() }.keyboardShortcut("l", modifiers: .command)
            Divider()
            Button("Now Playing") { withAnimation(.smooth(duration: 0.4)) { app.showNowPlaying.toggle() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Lyrics") { app.toggleInspector(.lyrics) }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Up Next") { app.toggleInspector(.queue) }.keyboardShortcut("u", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Button("Home") { app.showNowPlaying = false; app.selection = .home }.keyboardShortcut("1", modifiers: .command)
            Button("Liked Songs") { app.showNowPlaying = false; app.selection = .liked }.keyboardShortcut("2", modifiers: .command)
            Button("Playlists") { app.showNowPlaying = false; app.selection = .playlists }.keyboardShortcut("3", modifiers: .command)
            Button("Back") { if !app.path.isEmpty { app.path.removeLast() } }.keyboardShortcut("[", modifiers: .command)
            Divider()
        }
    }
}
