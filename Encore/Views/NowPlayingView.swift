import SwiftUI

/// Full-window Now Playing: the artwork's own colours fill the room,
/// lyrics or the queue sit beside it.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @State private var side: AppModel.InspectorTab = .lyrics

    var body: some View {
        let p = app.player
        ZStack {
            background(p.current?.thumb)
            if let t = p.current {
                GeometryReader { geo in
                    let artSize = min(geo.size.height * 0.52, geo.size.width * 0.34, 520)
                    HStack(spacing: 56) {
                        VStack(alignment: .leading, spacing: 22) {
                            Artwork(thumb: t.thumb, size: artSize, radius: 16, px: 1200)
                                .shadow(color: .black.opacity(0.45), radius: 40, y: 22)
                                .scaleEffect(p.isPlaying ? 1 : 0.94)
                                .animation(.spring(duration: 0.5, bounce: 0.3), value: p.isPlaying)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(t.title).font(.system(size: 26, weight: .bold)).lineLimit(2)
                                    Spacer()
                                    Button { p.toggleLike() } label: {
                                        Image(systemName: p.liked == true ? "heart.fill" : "heart")
                                            .font(.system(size: 20, weight: .semibold))
                                            .contentTransition(.symbolEffect(.replace))
                                    }
                                    .buttonStyle(.plain)
                                }
                                ArtistLinks(artists: t.artists).font(.title3.weight(.medium)).opacity(0.75)
                                if let a = t.album {
                                    Text(a.name).font(.callout).opacity(0.55).lineLimit(1)
                                        .onTapGesture { app.openAlbum(a) }
                                }
                            }
                            .foregroundStyle(.white)
                            Scrubber(tint: .white, height: 5)
                            TransportControls(big: true)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                            VolumeControl(width: artSize - 40)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(width: artSize)

                        VStack(spacing: 14) {
                            Picker("", selection: $side) {
                                Text("Lyrics").tag(AppModel.InspectorTab.lyrics)
                                Text("Up Next").tag(AppModel.InspectorTab.queue)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                            if side == .lyrics {
                                LyricsView(fontSize: 30, tint: .white)
                            } else {
                                QueueList(tint: .white)
                            }
                        }
                        .frame(maxWidth: 620)
                    }
                    .padding(.horizontal, 64)
                    .padding(.vertical, 48)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { withAnimation(.smooth(duration: 0.35)) { app.showNowPlaying = false } } label: {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold)).frame(width: 34, height: 34)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(.trailing, 22)
            .padding(.top, 22)
            .help("Close (Esc)")
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    private func background(_ thumb: Thumb?) -> some View {
        ZStack {
            Color.black
            AsyncImage(url: thumb?.sized(300)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: 90, opaque: true)
                    .saturation(1.5)
                    .scaleEffect(1.3)
            } placeholder: { Color.black }
            .id(thumb?.url)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.8), value: thumb?.url)
            // Keeps white text readable over pale covers.
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }
}
