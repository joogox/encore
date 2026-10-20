import SwiftUI

// MARK: - Scrubber

struct Scrubber: View {
    @Environment(AppModel.self) private var app
    var tint: Color = .primary
    var showTimes = true
    var height: CGFloat = 4

    @State private var dragging: Double?
    @State private var hover = false

    var body: some View {
        let p = app.player
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !p.isPlaying || dragging != nil)) { ctx in
            let t = dragging ?? p.time(at: ctx.date)
            let frac = p.duration > 0 ? min(1, max(0, t / p.duration)) : 0
            HStack(spacing: 10) {
                if showTimes { time(t).frame(width: 44, alignment: .trailing) }
                GeometryReader { geo in
                    let h = hover || dragging != nil ? height + 2 : height
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.18))
                        Capsule().fill(tint.opacity(p.isAd ? 0.4 : 0.85)).frame(width: max(h, geo.size.width * frac))
                        if hover || dragging != nil {
                            Circle().fill(tint).frame(width: 12, height: 12)
                                .shadow(color: .black.opacity(0.25), radius: 3)
                                .offset(x: geo.size.width * frac - 6)
                        }
                    }
                    .frame(height: h)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard p.duration > 0, !p.isAd else { return }
                            dragging = min(1, max(0, v.location.x / geo.size.width)) * p.duration
                        }
                        .onEnded { _ in
                            if let d = dragging { p.seek(to: d) }
                            dragging = nil
                        })
                }
                .frame(height: 14)
                .onHover { h in withAnimation(.smooth(duration: 0.15)) { hover = h } }
                if showTimes { time(p.duration > 0 ? p.duration : nil).frame(width: 44, alignment: .leading) }
            }
        }
    }

    private func time(_ t: Double?) -> some View {
        Text(formatTime(t)).font(.caption.monospacedDigit()).foregroundStyle(tint.opacity(0.6))
    }
}

// MARK: - Transport

struct TransportControls: View {
    @Environment(AppModel.self) private var app
    var big = false

    var body: some View {
        let p = app.player
        HStack(spacing: big ? 26 : 16) {
            Button { p.toggleShuffle() } label: { Image(systemName: "shuffle") }
                .foregroundStyle(p.shuffled ? Color.encore : .secondary)
                .help("Shuffle")
            Button { p.previous() } label: { Image(systemName: "backward.fill") }
                .help("Previous")
            Button { p.toggle() } label: {
                Image(systemName: p.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: big ? 30 : 20, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: big ? 64 : 38, height: big ? 64 : 38)
                    .overlay {
                        if p.isBuffering && p.isPlaying {
                            ProgressView().controlSize(.small).offset(y: big ? 44 : 28)
                        }
                    }
            }
            .help(p.isPlaying ? "Pause" : "Play")
            Button { p.next() } label: { Image(systemName: "forward.fill") }
                .help("Next")
            Button { p.cycleRepeat() } label: {
                Image(systemName: p.repeatMode == .one ? "repeat.1" : "repeat")
            }
            .foregroundStyle(p.repeatMode == .off ? .secondary : Color.encore)
            .help("Repeat")
        }
        .buttonStyle(.plain)
        .font(.system(size: big ? 22 : 15, weight: .semibold))
    }
}

struct VolumeControl: View {
    @Environment(AppModel.self) private var app
    var width: CGFloat = 96

    var body: some View {
        @Bindable var player = app.player
        HStack(spacing: 6) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : player.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary).frame(width: 18)
            Slider(value: $player.volume, in: 0...1).controlSize(.mini).frame(width: width)
        }
    }
}

// MARK: - Player bar

struct PlayerBar: View {
    @Environment(AppModel.self) private var app
    @State private var width: CGFloat = 1000

    var body: some View {
        let p = app.player
        if let t = p.current {
            HStack(spacing: 14) {
                Button { withAnimation(.smooth(duration: 0.4)) { app.showNowPlaying = true } } label: {
                    Artwork(thumb: t.thumb, size: 46, radius: 7)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "chevron.up").font(.system(size: 9, weight: .heavy))
                                .padding(3).background(.black.opacity(0.5), in: Circle()).foregroundStyle(.white)
                                .padding(3)
                        }
                }
                .buttonStyle(.plain)
                .help("Now Playing")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(t.title).font(.callout.weight(.semibold)).lineLimit(1)
                        if p.isAd {
                            Text("AD").font(.caption2.weight(.heavy)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.yellow.opacity(0.85), in: Capsule()).foregroundStyle(.black)
                        }
                    }
                    ArtistLinks(artists: t.artists).font(.caption).foregroundStyle(.secondary)
                }
                .frame(minWidth: 120, maxWidth: 240, alignment: .leading)

                VStack(spacing: 2) {
                    TransportControls()
                    Scrubber()
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 14) {
                    Button { p.toggleLike() } label: {
                        Image(systemName: p.liked == true ? "heart.fill" : "heart")
                            .foregroundStyle(p.liked == true ? Color.pink : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help("Like")
                    Button { app.toggleInspector(.lyrics) } label: {
                        Image(systemName: "quote.bubble").foregroundStyle(app.inspector == .lyrics ? Color.encore : .secondary)
                    }
                    .help("Lyrics")
                    Button { app.toggleInspector(.queue) } label: {
                        Image(systemName: "list.bullet").foregroundStyle(app.inspector == .queue ? Color.encore : .secondary)
                    }
                    .help("Up Next")
                    if width > 860 { VolumeControl(width: 80) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        }
    }
}

// MARK: - Inspector (lyrics / up next)

struct InspectorPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { app.inspector ?? .lyrics }, set: { app.inspector = $0 })) {
                Text("Lyrics").tag(AppModel.InspectorTab.lyrics)
                Text("Up Next").tag(AppModel.InspectorTab.queue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            if app.inspector == .queue { QueueList() } else { LyricsView(fontSize: 19) }
        }
    }
}

struct LyricsView: View {
    @Environment(AppModel.self) private var app
    var fontSize: CGFloat = 19
    var tint: Color = .primary
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        let p = app.player
        if let l = p.lyrics {
            if l.synced { SyncedLyrics(lyrics: l, fontSize: fontSize, tint: tint, alignment: alignment) }
            else {
                ScrollView {
                    VStack(alignment: alignment, spacing: 8) {
                        ForEach(l.lines) { Text($0.text.isEmpty ? " " : $0.text) }
                        Text(l.source).font(.caption).foregroundStyle(tint.opacity(0.4)).padding(.top, 20)
                    }
                    .font(.system(size: fontSize * 0.85, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
                    .padding(20)
                }
            }
        } else if p.lyricsLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No lyrics", systemImage: "quote.bubble")
                .foregroundStyle(tint.opacity(0.6))
        }
    }
}

struct SyncedLyrics: View {
    @Environment(AppModel.self) private var app
    let lyrics: Lyrics
    var fontSize: CGFloat
    var tint: Color
    var alignment: HorizontalAlignment

    @State private var active: Int?
    @State private var userScrolled = Date.distantPast

    var body: some View {
        let p = app.player
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: alignment, spacing: fontSize * 0.75) {
                    Color.clear.frame(height: 60)
                    ForEach(lyrics.lines) { line in
                        let isActive = line.id == active
                        let past = (active ?? -1) > line.id
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: fontSize, weight: .bold))
                            .multilineTextAlignment(alignment == .center ? .center : .leading)
                            .foregroundStyle(tint.opacity(isActive ? 1 : past ? 0.32 : 0.45))
                            .scaleEffect(isActive ? 1.0 : 0.97, anchor: alignment == .center ? .center : .leading)
                            .blur(radius: isActive || active == nil ? 0 : 0.4)
                            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
                            .contentShape(Rectangle())
                            .onTapGesture { if let t = line.time { p.seek(to: t) } }
                            .id(line.id)
                    }
                    Text(lyrics.source).font(.caption).foregroundStyle(tint.opacity(0.35)).padding(.top, 24)
                    Color.clear.frame(height: 200)
                }
                .padding(.horizontal, 22)
                .animation(.smooth(duration: 0.35), value: active)
            }
            .scrollIndicators(.never)
            .onScrollPhaseChange { _, phase in if phase == .interacting { userScrolled = .now } }
            .background {
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    Color.clear.onChange(of: lyrics.index(at: p.time(at: ctx.date) + 0.25)) { _, i in
                        active = i
                        guard let i, Date.now.timeIntervalSince(userScrolled) > 3 else { return }
                        withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0.5, y: 0.35)) }
                    }
                }
            }
        }
    }
}

struct QueueList: View {
    @Environment(AppModel.self) private var app
    var tint: Color = .primary

    var body: some View {
        let p = app.player
        List {
            if let t = p.current {
                Section("Now Playing") { QueueRow(track: t, current: true, tint: tint) }
            }
            Section {
                ForEach(Array(p.upNext.enumerated()), id: \.offset) { off, t in
                    let i = (p.index ?? 0) + 1 + off
                    QueueRow(track: t, current: false, tint: tint)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { p.jump(to: i) }
                        .contextMenu {
                            Button("Play Now") { p.jump(to: i) }
                            Button("Remove from Queue", role: .destructive) { p.remove(at: i) }
                        }
                }
                .onMove { src, dst in
                    let base = (p.index ?? 0) + 1
                    p.move(from: IndexSet(src.map { $0 + base }), to: dst + base)
                }
            } header: {
                HStack {
                    Text("Up Next")
                    Spacer()
                    Toggle("Autoplay", isOn: Binding(get: { p.autoplay }, set: { p.autoplay = $0 }))
                        .toggleStyle(.switch).controlSize(.mini)
                    if !p.upNext.isEmpty { Button("Clear") { p.clearUpNext() }.buttonStyle(.link) }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

struct QueueRow: View {
    let track: Track
    let current: Bool
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 10) {
            Artwork(thumb: track.thumb, size: 38, radius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.callout.weight(current ? .bold : .medium)).lineLimit(1).foregroundStyle(tint)
                Text(track.artistLine).font(.caption).lineLimit(1).foregroundStyle(tint.opacity(0.6))
            }
            Spacer()
            Text(formatTime(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(tint.opacity(0.5))
        }
        .padding(.vertical, 2)
    }
}
