import AppKit
import SwiftUI
import WebKit

enum SidebarItem: Hashable {
    case home, search, liked, playlists, albums, artists, history
    case playlist(Card)
}

enum Route: Hashable {
    case page(Destination)
}

@Observable
final class AppModel {
    static let shared = AppModel()

    let engine: WebEngine
    let api: YTMusic
    let player: Player

    var selection: SidebarItem? = .home
    var path: [Route] = []
    var searchText = ""
    var submittedSearch = ""
    var showSignIn = false
    var showNowPlaying = false
    var inspector: InspectorTab? = nil
    var account: YTMusic.Account?
    var playlists: [Card] = []
    var toast: String?

    enum InspectorTab: String { case lyrics, queue }

    private var keyMonitor: Any?

    init() {
        URLCache.shared = URLCache(memoryCapacity: 160 << 20, diskCapacity: 1 << 30)
        engine = WebEngine()
        api = YTMusic(engine: engine)
        player = Player(engine: engine, api: api)
        installKeys()
        Task { await refreshAccount() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.persistPosition() }
        }
    }

    var isSignedIn: Bool { account != nil }

    func refreshAccount() async {
        await engine.waitUntilReady()
        guard engine.isLoggedIn else { account = nil; playlists = []; return }
        account = try? await api.account()
        playlists = (try? await api.libraryCards("FEmusic_liked_playlists"))?.filter {
            if case .open(let d) = $0.action { return d.kind == .playlist && d.browseId != "VLLM" }
            return false
        } ?? []
    }

    func signedIn() {
        showSignIn = false
        engine.reload()
        Task { await refreshAccount() }
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        account = nil
        playlists = []
        selection = .home
        path = []
        engine.reload()
    }

    /// Set by the window's root view; reopens the main window after it was closed.
    var openMainWindow: (() -> Void)?

    func showMainWindow() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate()
    }

    func open(_ d: Destination) {
        showNowPlaying = false
        path.append(.page(d))
    }

    func openArtist(_ a: ArtistRef) {
        guard let id = a.id else { return }
        open(Destination(browseId: id, kind: .artist, title: a.name))
    }

    func openAlbum(_ a: AlbumRef) {
        open(Destination(browseId: a.id, kind: .album, title: a.name))
    }

    func perform(_ c: Card) {
        switch c.action {
        case .open(let d): open(d)
        case .play(let t): player.startRadio(from: t)
        case .playlist(let id): player.playPlaylist(id: id)
        }
    }

    func say(_ s: String) {
        withAnimation(.smooth) { toast = s }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if toast == s { withAnimation(.smooth) { toast = nil } }
        }
    }

    func toggleInspector(_ tab: InspectorTab) {
        withAnimation(.smooth(duration: 0.3)) { inspector = inspector == tab ? nil : tab }
    }

    /// True while a text field or a web page (the sign-in sheet) has the keyboard.
    private var isTyping: Bool {
        guard let r = NSApp.keyWindow?.firstResponder else { return false }
        if r is NSText { return true }
        var v = r as? NSView
        while let view = v {
            if view is WKWebView { return true }
            v = view.superview
        }
        return false
    }

    /// Space plays/pauses unless a text field has focus (as in Music.app).
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !self.isTyping else { return e }
            if e.keyCode == 49, mods.isEmpty, !e.isARepeat {
                self.player.toggle()
                return nil
            }
            // ⌘ arrows: transport and volume (kept out of the menu so text fields keep them).
            if mods == .command {
                switch e.keyCode {
                case 124: self.player.next(); return nil
                case 123: self.player.previous(); return nil
                case 126: self.player.volume = min(1, self.player.volume + 0.1); return nil
                case 125: self.player.volume = max(0, self.player.volume - 0.1); return nil
                default: break
                }
            }
            if e.keyCode == 53, self.showNowPlaying {
                withAnimation(.smooth(duration: 0.35)) { self.showNowPlaying = false }
                return nil
            }
            return e
        }
    }
}
