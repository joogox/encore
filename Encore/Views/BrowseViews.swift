import SwiftUI

/// Loads once per identity and keeps the result while the view lives.
struct Loader<Value, Content: View>: View {
    let id: String
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content

    @State private var value: Value?
    @State private var error: String?
    @State private var loadedId: String?

    var body: some View {
        Group {
            if let value, loadedId == id { content(value) }
            else if let error { ErrorView(message: error) { Task { await run() } } }
            else { LoadingView() }
        }
        .task(id: id) { if loadedId != id { await run() } }
    }

    private func run() async {
        error = nil
        do {
            let v = try await load()
            // A superseded load (filter switched, sign-in arrived) must not win.
            guard !Task.isCancelled else { return }
            value = v
            loadedId = id
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private func greeting() -> String {
    switch Calendar.current.component(.hour, from: .now) {
    case 5..<12: "Good morning"
    case 12..<18: "Good afternoon"
    default: "Good evening"
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Loader(id: "home-\(app.isSignedIn)", load: { try await app.api.home() }) { shelves in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    Text(app.account.map { "\(greeting()), \($0.name.components(separatedBy: " ").first ?? $0.name)" } ?? greeting())
                        .font(.largeTitle.weight(.bold))
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                    ForEach(shelves) { ShelfView(shelf: $0) }
                }
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("Home")
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: YTMusic.SearchFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(YTMusic.SearchFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
            .padding(.vertical, 10)

            Loader(id: "\(app.submittedSearch)|\(filter.rawValue)", load: { try await app.api.search(app.submittedSearch, filter: filter) }) { r in
                if r.top == nil && r.shelves.isEmpty {
                    ContentUnavailableView.search(text: app.submittedSearch)
                } else {
                    results(r)
                }
            }
        }
        .navigationTitle(app.submittedSearch)
    }

    private func results(_ r: SearchResults) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if let top = r.top { TopResult(card: top, tracks: r.topTracks) }
                ForEach(r.shelves) { shelf in
                    if case .tracks(let tracks) = shelf.content {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(shelf.title).font(.title2.weight(.bold)).padding(.horizontal, 28)
                            LazyVStack(spacing: 0) {
                                ForEach(tracks) { t in
                                    TrackRow(track: t) { app.player.startRadio(from: t) }
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                    } else {
                        ShelfView(shelf: shelf)
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }
}

struct TopResult: View {
    @Environment(AppModel.self) private var app
    let card: Card
    let tracks: [Track]

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Artwork(thumb: card.thumb, size: 150, radius: 10, round: card.round, px: 400)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                Text(card.title).font(.title.weight(.bold)).lineLimit(2)
                Text(card.subtitle).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Button {
                        if case .play(let t) = card.action { app.player.startRadio(from: t) }
                        else if !tracks.isEmpty { app.player.play(tracks) }
                        else { app.perform(card) }
                    } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.glassProminent)
                    if case .open = card.action {
                        Button("Open") { app.perform(card) }.buttonStyle(.glass)
                    }
                }
                .controlSize(.large)
            }
            .frame(width: 260, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { app.perform(card) }

            if !tracks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(tracks.prefix(4).enumerated()), id: \.element.id) { i, t in
                        TrackRow(track: t, showAlbum: false) { app.player.play(tracks, at: i) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.primary.opacity(0.04)))
        .padding(.horizontal, 20)
    }
}

struct LibraryGrid: View {
    @Environment(AppModel.self) private var app
    let title: String
    let browseId: String

    var body: some View {
        Loader(id: browseId, load: { try await app.api.libraryCards(browseId) }) { cards in
            if cards.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "music.note.house")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 200), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                        ForEach(cards) { CardView(card: $0) }
                    }
                    .padding(28)
                }
            }
        }
        .navigationTitle(title)
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Loader(id: "history", load: { try await app.api.history() }) { shelves in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(shelves) { shelf in
                        if case .tracks(let tracks) = shelf.content {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(shelf.title).font(.title3.weight(.bold)).padding(.horizontal, 28)
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                                        TrackRow(track: t) { app.player.play(tracks, at: i) }
                                    }
                                }
                                .padding(.horizontal, 18)
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("History")
    }
}
