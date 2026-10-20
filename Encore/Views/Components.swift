import SwiftUI

// MARK: - Artwork

struct Artwork: View {
    let thumb: Thumb?
    var size: CGFloat
    var radius: CGFloat = 6
    var round = false
    var px: Int? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: round ? size / 2 : radius, style: .continuous)
        AsyncImage(url: thumb?.sized(px ?? Int(size * 2)), transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    LinearGradient(colors: [.secondary.opacity(0.18), .secondary.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: round ? "person.fill" : "music.note")
                        .font(.system(size: size * 0.3, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
}

// MARK: - Equalizer

/// Three bars that dance while the row's track plays.
struct PlayingBars: View {
    var playing: Bool
    var color: Color = .encore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3) { i in
                    let h = playing ? 0.35 + 0.65 * abs(sin(t * (5.2 + Double(i) * 1.7) + Double(i))) : 0.3
                    Capsule().fill(color).frame(width: 3, height: 14 * h)
                }
            }
            .frame(width: 14, height: 14, alignment: .bottom)
        }
    }
}

func formatTime(_ t: Double?) -> String {
    guard let t, t.isFinite, t >= 0 else { return "–:––" }
    let s = Int(t.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Track row

struct TrackRow: View {
    @Environment(AppModel.self) private var app
    let track: Track
    var number: Int? = nil
    var showArt = true
    var showAlbum = true
    var play: () -> Void

    @State private var hover = false

    private var isCurrent: Bool { app.player.current?.videoId == track.videoId }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if showArt {
                    Artwork(thumb: track.thumb, size: 40, radius: 5)
                        .overlay {
                            if hover || isCurrent {
                                RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.45))
                                icon.foregroundStyle(.white)
                            }
                        }
                } else {
                    if hover || isCurrent { icon.foregroundStyle(isCurrent ? Color.encore : .primary) }
                    else { Text(number.map(String.init) ?? "").monospacedDigit().foregroundStyle(.secondary) }
                }
            }
            .frame(width: showArt ? 40 : 28, height: 40)
            .contentShape(Rectangle())
            .onTapGesture {
                // The second click of a double-click belongs to the row's double-tap.
                guard (NSApp.currentEvent?.clickCount ?? 1) == 1 else { return }
                isCurrent ? app.player.toggle() : play()
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                        .foregroundStyle(isCurrent ? Color.encore : .primary)
                    if track.isVideo {
                        Image(systemName: "play.rectangle.fill").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                ArtistLinks(artists: track.artists).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showAlbum, let album = track.album {
                Button(album.name) { app.openAlbum(album) }
                    .buttonStyle(.link).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
            }

            TrackMenu(track: track)
                .opacity(hover ? 1 : 0)

            if track.duration != nil || showAlbum {
                Text(track.duration.map(formatTime) ?? "").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { play() }
        .contextMenu { TrackMenuItems(track: track) }
    }

    @ViewBuilder private var icon: some View {
        if isCurrent && app.player.isPlaying && !hover {
            PlayingBars(playing: true, color: showArt ? .white : .encore)
        } else {
            Image(systemName: isCurrent && app.player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
        }
    }
}

struct ArtistLinks: View {
    @Environment(AppModel.self) private var app
    let artists: [ArtistRef]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { i, a in
                if i > 0 { Text(", ") }
                if a.id != nil {
                    Text(a.name).onTapGesture { app.openArtist(a) }
                        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                } else {
                    Text(a.name)
                }
            }
        }
        .lineLimit(1)
    }
}

struct TrackMenu: View {
    let track: Track
    var body: some View {
        Menu { TrackMenuItems(track: track) } label: {
            Image(systemName: "ellipsis").frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct TrackMenuItems: View {
    @Environment(AppModel.self) private var app
    let track: Track

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            app.player.playNext(track); app.say("Playing next: \(track.title)")
        }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
            app.player.addToQueue(track); app.say("Added to queue")
        }
        Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { app.player.startRadio(from: track) }
        Divider()
        Button("Like", systemImage: "heart") { app.player.like(track, true); app.say("Added to Liked Songs") }
        if app.isSignedIn, !app.playlists.isEmpty {
            Menu("Add to Playlist", systemImage: "music.note.list") {
                ForEach(app.playlists) { p in
                    Button(p.title) {
                        guard case .open(let d) = p.action else { return }
                        Task {
                            do { try await app.api.addToPlaylist(String(d.browseId.dropFirst(2)), videoId: track.videoId); app.say("Added to \(p.title)") }
                            catch { app.say(error.localizedDescription) }
                        }
                    }
                }
            }
        }
        Divider()
        if let album = track.album { Button("Go to Album", systemImage: "square.stack") { app.openAlbum(album) } }
        ForEach(track.artists.filter { $0.id != nil }, id: \.self) { a in
            Button("Go to \(a.name)", systemImage: "music.microphone") { app.openArtist(a) }
        }
        Divider()
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("https://music.youtube.com/watch?v=\(track.videoId)", forType: .string)
            app.say("Link copied")
        }
    }
}

// MARK: - Cards

struct CardView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    var width: CGFloat = 168

    @State private var hover = false

    var body: some View {
        let artW = card.wide ? width * 16 / 9 * 0.75 : width
        VStack(alignment: card.round ? .center : .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                if card.wide {
                    AsyncImage(url: card.thumb?.sized(480)) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.secondary.opacity(0.12) }
                        .frame(width: artW, height: width * 0.75)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Artwork(thumb: card.thumb, size: width, radius: 8, round: card.round, px: 400)
                }
                if hover, !card.round {
                    Button { quickPlay() } label: {
                        Image(systemName: "play.fill").font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .padding(8)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .scaleEffect(hover ? 1.02 : 1)
            .shadow(color: .black.opacity(hover ? 0.25 : 0.12), radius: hover ? 14 : 6, y: hover ? 8 : 3)

            VStack(alignment: card.round ? .center : .leading, spacing: 2) {
                Text(card.title).font(.callout.weight(.semibold)).lineLimit(2)
                    .multilineTextAlignment(card.round ? .center : .leading)
                Text(card.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: artW, alignment: card.round ? .center : .leading)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.smooth(duration: 0.2)) { hover = h } }
        .onTapGesture { app.perform(card) }
    }

    private func quickPlay() {
        switch card.action {
        case .play(let t): app.player.startRadio(from: t)
        case .playlist(let id): app.player.playPlaylist(id: id)
        case .open(let d):
            Task {
                guard let page = try? await app.api.collection(d.browseId) else { return }
                app.player.play(await app.api.allTracks(of: page, limit: 300))
            }
        }
    }
}

// MARK: - Shelves

struct ShelfView: View {
    @Environment(AppModel.self) private var app
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(shelf.title).font(.title2.weight(.bold))
                Spacer()
                if let more = shelf.more, more.kind != .other {
                    Button("See All") { app.open(more) }.buttonStyle(.link)
                }
            }
            .padding(.horizontal, 28)

            switch shelf.content {
            case .cards(let cards):
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(cards) { CardView(card: $0) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.never)
            case .tracks(let tracks):
                TrackGrid(tracks: tracks)
            }
        }
    }
}

/// "Quick picks"-style shelf: four rows that scroll sideways.
struct TrackGrid: View {
    @Environment(AppModel.self) private var app
    let tracks: [Track]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(50), spacing: 2), count: min(4, max(1, tracks.count))), spacing: 18) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                    TrackRow(track: t, showAlbum: false) { app.player.play(tracks, at: i) }
                        .frame(width: 360)
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - States

struct LoadingView: View {
    var body: some View {
        ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    let message: String
    var retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry).buttonStyle(.glass)
        }
    }
}
