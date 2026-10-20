import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var suggestions: [String] = []

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            NavigationStack(path: $app.path) {
                section
                    .modifier(PlayerInset())
                    .navigationDestination(for: Route.self) { route in
                        Group {
                            switch route {
                            case .page(let d) where d.kind == .artist: ArtistView(dest: d)
                            case .page(let d): CollectionView(dest: d)
                            }
                        }
                        .modifier(PlayerInset())
                    }
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if app.inspector != nil && !app.showNowPlaying {
                    InspectorPanel()
                        .frame(width: 340)
                        .frame(maxHeight: .infinity)
                        .background(.background)
                        .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .searchable(text: $app.searchText, placement: .sidebar, prompt: "Songs, albums, artists")
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { s in
                Label(s, systemImage: "magnifyingglass").searchCompletion(s)
            }
        }
        .task(id: app.searchText) {
            let q = app.searchText.trimmingCharacters(in: .whitespaces)
            guard q.count > 1, q != app.submittedSearch else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            suggestions = (try? await app.api.suggestions(q)) ?? []
        }
        .onSubmit(of: .search) {
            app.submittedSearch = app.searchText
            app.path = []
            app.selection = .search
        }
        .overlay {
            if app.showNowPlaying {
                NowPlayingView()
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .bottom)).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .overlay(alignment: .top) {
            if let t = app.toast {
                Text(t)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .toolbar(app.showNowPlaying ? .hidden : .automatic, for: .windowToolbar)
        .sheet(isPresented: $app.showSignIn) { SignInSheet() }
        .onChange(of: app.selection) { app.path = [] }
        .onAppear { app.openMainWindow = { [openWindow] in openWindow(id: "main") } }
        .onChange(of: app.player.error) { _, e in if let e { app.say(e) } }
        .frame(minWidth: 940, minHeight: 600)
    }

    @ViewBuilder private var section: some View {
        switch app.selection ?? .home {
        case .home: HomeView()
        case .search: SearchView()
        case .liked: CollectionView(dest: Destination(browseId: "VLLM", kind: .playlist, title: "Liked Songs"))
        case .playlists: LibraryGrid(title: "Playlists", browseId: "FEmusic_liked_playlists")
        case .albums: LibraryGrid(title: "Albums", browseId: "FEmusic_liked_albums")
        case .artists: LibraryGrid(title: "Artists", browseId: "FEmusic_library_corpus_track_artists")
        case .history: HistoryView()
        case .playlist(let c):
            if case .open(let d) = c.action { CollectionView(dest: d).id(d.browseId) }
        }
    }
}

/// The floating player bar; every page gets it so content scrolls beneath.
struct PlayerInset: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if app.player.current != nil && !app.showNowPlaying {
                PlayerBar()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                if !app.submittedSearch.isEmpty {
                    Label(app.submittedSearch, systemImage: "magnifyingglass").tag(SidebarItem.search)
                }
            }
            Section("Library") {
                Label("Liked Songs", systemImage: "heart").tag(SidebarItem.liked)
                Label("Playlists", systemImage: "music.note.list").tag(SidebarItem.playlists)
                Label("Albums", systemImage: "square.stack").tag(SidebarItem.albums)
                Label("Artists", systemImage: "music.microphone").tag(SidebarItem.artists)
                Label("History", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
            }
            .disabled(!app.isSignedIn)
            if !app.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(app.playlists) { p in
                        HStack(spacing: 8) {
                            Artwork(thumb: p.thumb, size: 22, radius: 4)
                            Text(p.title).lineLimit(1)
                        }
                        .tag(SidebarItem.playlist(p))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { AccountFooter() }
    }
}

struct AccountFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            if let a = app.account {
                Artwork(thumb: a.photo, size: 28, round: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(a.name).font(.callout.weight(.medium)).lineLimit(1)
                    if let h = a.handle { Text(h).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Menu {
                    Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            } else {
                Button { app.showSignIn = true } label: {
                    Label("Sign in to YouTube Music", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(12)
    }
}
