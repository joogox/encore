import SwiftUI

/// Soft blurred artwork behind a page header, fading into the window.
struct ArtBackdrop: View {
    let thumb: Thumb?
    var height: CGFloat = 420

    var body: some View {
        AsyncImage(url: thumb?.sized(200)) { img in
            img.resizable().aspectRatio(contentMode: .fill)
                .blur(radius: 70, opaque: true)
                .saturation(1.4)
                .opacity(0.55)
        } placeholder: { Color.clear }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }
}

struct CollectionView: View {
    @Environment(AppModel.self) private var app
    let dest: Destination

    var body: some View {
        Loader(id: dest.browseId, load: { try await app.api.collection(dest.browseId) }) { page in
            CollectionBody(page: page)
        }
        .navigationTitle(dest.title)
    }
}

private struct CollectionBody: View {
    @Environment(AppModel.self) private var app
    @State var page: CollectionPage
    @State private var loadingMore = false
    @State private var filter = ""
    @State private var expanded = false

    private var shown: [(Int, Track)] {
        let all = Array(page.tracks.enumerated())
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.1.title.lowercased().contains(q) || $0.1.artistLine.lowercased().contains(q) || ($0.1.album?.name.lowercased().contains(q) ?? false) }
    }

    var body: some View {
        ScrollView {
            ZStack(alignment: .top) {
                ArtBackdrop(thumb: page.thumb)
                VStack(alignment: .leading, spacing: 26) {
                    header
                    tracks
                }
                .padding(.vertical, 24)
            }
        }
        .onChange(of: filter) { _, q in if !q.isEmpty { loadAll() } }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 26) {
            Artwork(thumb: page.thumb, size: 220, radius: 12, px: 600)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
            VStack(alignment: .leading, spacing: 8) {
                Text(page.subtitle.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                Text(page.title).font(.system(size: 38, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                if !page.artists.isEmpty {
                    ArtistLinks(artists: page.artists).font(.title3.weight(.medium))
                }
                if !page.detail.isEmpty { Text(page.detail).foregroundStyle(.secondary) }
                if let d = page.description, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                        .frame(maxWidth: 560, alignment: .leading)
                        .onTapGesture { withAnimation(.smooth) { expanded.toggle() } }
                }
                HStack(spacing: 10) {
                    Button { playAll(shuffle: false) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 70) }
                        .buttonStyle(.glassProminent)
                    Button { playAll(shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(.glass)
                    if let pl = page.playlistId {
                        Button { app.player.startRadio(playlistId: pl) } label: { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                            .buttonStyle(.glass)
                    }
                    Spacer(minLength: 20)
                    if page.tracks.count > 12 {
                        TextField("Filter", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
    }

    private var tracks: some View {
        LazyVStack(spacing: 0) {
            ForEach(shown, id: \.0) { i, t in
                TrackRow(track: t, number: i + 1, showArt: page.kind != .album, showAlbum: page.kind != .album) {
                    play(from: i)
                }
                .onAppear { if i == page.tracks.count - 1 { loadMore() } }
            }
            if loadingMore { ProgressView().padding() }
        }
        .padding(.horizontal, 18)
    }

    private func play(from i: Int) {
        app.player.play(page.tracks, at: i)
        if page.continuation != nil {
            let known = page.tracks.count
            let lastId = page.tracks.last?.videoId
            Task {
                let all = await app.api.allTracks(of: page)
                page.tracks = all
                page.continuation = nil
                // The rest of a long playlist joins the queue that just started.
                app.player.extend(after: lastId, with: Array(all.dropFirst(known)))
            }
        }
    }

    private func playAll(shuffle: Bool) {
        Task {
            let all = page.continuation == nil ? page.tracks : await app.api.allTracks(of: page)
            page.tracks = all
            page.continuation = nil
            app.player.play(all, shuffle: shuffle)
        }
    }

    private func loadMore() {
        guard let c = page.continuation, !loadingMore else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            guard let r = try? await app.api.more(c, page: page) else { return }
            page.tracks += r.0
            page.continuation = r.1
        }
    }

    private func loadAll() {
        guard page.continuation != nil, !loadingMore else { return }
        loadingMore = true
        Task {
            let all = await app.api.allTracks(of: page)
            page.tracks = all
            page.continuation = nil
            loadingMore = false
        }
    }
}

struct ArtistView: View {
    @Environment(AppModel.self) private var app
    let dest: Destination

    var body: some View {
        Loader(id: dest.browseId, load: { try await app.api.artist(dest.browseId) }) { a in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    hero(a)
                    ForEach(a.shelves) { shelf in
                        if case .tracks(let tracks) = shelf.content, shelf.title.lowercased().contains("song") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(shelf.title).font(.title2.weight(.bold))
                                    Spacer()
                                    if let more = shelf.more { Button("See All") { app.open(more) }.buttonStyle(.link) }
                                }
                                .padding(.horizontal, 28)
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(tracks.prefix(5).enumerated()), id: \.element.id) { i, t in
                                        TrackRow(track: t) { app.player.play(tracks, at: i) }
                                    }
                                }
                                .padding(.horizontal, 18)
                            }
                        } else {
                            ShelfView(shelf: shelf)
                        }
                    }
                    if let d = a.description, !d.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About").font(.title2.weight(.bold))
                            Text(d).foregroundStyle(.secondary).frame(maxWidth: 680, alignment: .leading)
                        }
                        .padding(.horizontal, 28)
                    }
                }
                .padding(.bottom, 30)
            }
            .ignoresSafeArea(edges: .top)
        }
        .navigationTitle(dest.title)
    }

    private func hero(_ a: ArtistPage) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: a.banner?.sized(1440).flatMap { URL(string: $0.absoluteString.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w1440-h600", options: .regularExpression)) }) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                LinearGradient(colors: [.secondary.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: 380)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 10) {
                Text(a.name).font(.system(size: 56, weight: .heavy)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 10)
                if let l = a.listeners { Text(l).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8)) }
                HStack(spacing: 10) {
                    if let s = a.shuffle {
                        Button { app.player.playPlaylist(id: s) } label: { Label("Shuffle", systemImage: "shuffle") }
                            .buttonStyle(.glassProminent)
                    }
                    if let r = a.radio {
                        Button { app.player.startRadio(playlistId: r.playlistId, videoId: r.videoId) } label: { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                            .buttonStyle(.glass)
                    }
                }
                .controlSize(.large)
            }
            .padding(28)
        }
    }
}
