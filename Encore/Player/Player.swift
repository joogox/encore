import AppKit
import OSLog

/// Encore's queue and transport. The web page only ever plays `current`.
@Observable
final class Player {
    enum Repeat: String, Codable { case off, all, one }

    private(set) var queue: [Track] = []
    private(set) var index: Int?
    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var upNext: ArraySlice<Track> { index.map { queue.dropFirst($0 + 1) } ?? [] }
    var history: ArraySlice<Track> { index.map { queue.prefix($0) } ?? [] }

    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isAd = false
    private(set) var duration: Double = 0
    private var position: Double = 0
    private var positionStamp = Date()

    var volume: Double = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.8 {
        didSet { engine.setVolume(volume); UserDefaults.standard.set(volume, forKey: "volume") }
    }
    private(set) var shuffled = false
    var repeatMode: Repeat = Repeat(rawValue: UserDefaults.standard.string(forKey: "repeat") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeat") }
    }
    /// Keeps playing related music when the queue runs out.
    var autoplay: Bool = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") }
    }

    private(set) var liked: Bool?
    private(set) var lyrics: Lyrics?
    private(set) var lyricsLoading = false
    var error: String?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Encore", category: "player")
    private func note(_ s: String) { Self.logger.debug("\(s)") }

    private let engine: WebEngine
    private let api: YTMusic
    private var unshuffled: [Track]?
    private var radioToken: String?
    private var loadedId: String?
    private var pendingStart: Double = 0
    private var trackTask: Task<Void, Never>?
    /// Bumped whenever a new queue starts; late results for an older queue are dropped.
    private var epoch = 0
    private var fillTask: Task<Void, Never>?
    private var fillEpoch = -1
    private var fillId = 0
    /// Control Center's card is WebKit's (fed from the page's media session);
    /// Encore only tells the page what it is playing.
    private var metaSentFor: String?

    init(engine: WebEngine, api: YTMusic) {
        self.engine = engine
        self.api = api
        engine.onEvent = { [weak self] in self?.handle($0) }
        restore()
    }

    /// Interpolated playback time; cheap enough to read every frame.
    func time(at date: Date = .now) -> Double {
        guard isPlaying, !isBuffering else { return position }
        return min(duration > 0 ? duration : .infinity, position + date.timeIntervalSince(positionStamp))
    }

    // MARK: Starting playback

    func play(_ tracks: [Track], at start: Int = 0, shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
        var list = tracks
        var i = min(max(0, start), list.count - 1)
        unshuffled = nil
        shuffled = false
        if shuffle {
            unshuffled = list
            let first = list.remove(at: shuffle && start == 0 ? Int.random(in: 0..<list.count) : i)
            list.shuffle()
            list.insert(first, at: 0)
            i = 0
            shuffled = true
        }
        epoch += 1
        queue = list
        radioToken = nil
        startTrack(at: i)
    }

    /// A station seeded by one track (YouTube Music's "Start radio").
    func startRadio(from track: Track) {
        epoch += 1
        queue = [track]
        unshuffled = nil
        shuffled = false
        radioToken = nil
        startTrack(at: 0)
        fillRadio(seed: track, replaceUpcoming: true)
    }

    func startRadio(playlistId: String, videoId: String? = nil) {
        epoch += 1
        let mine = epoch
        Task {
            do {
                let w = try await api.watch(videoId: videoId, playlistId: playlistId, radio: true)
                guard !w.tracks.isEmpty, epoch == mine else { return }
                queue = w.tracks
                radioToken = w.continuation
                unshuffled = nil
                shuffled = false
                startTrack(at: 0)
            } catch { self.error = error.localizedDescription }
        }
    }

    func playPlaylist(id: String) {
        epoch += 1
        let mine = epoch
        Task {
            do {
                let w = try await api.watch(videoId: nil, playlistId: id)
                guard epoch == mine else { return }
                play(w.tracks)
                radioToken = w.continuation
            } catch { self.error = error.localizedDescription }
        }
    }

    func playNext(_ t: Track) {
        guard let i = index else { play([t]); return }
        queue.insert(t, at: i + 1)
        persist()
    }

    func addToQueue(_ t: Track) {
        guard index != nil else { play([t]); return }
        queue.append(t)
        persist()
    }

    /// Appends tracks if the queue still ends where the caller left it.
    func extend(after lastId: String?, with tracks: [Track]) {
        guard !tracks.isEmpty, queue.last?.videoId == lastId else { return }
        queue += tracks
        persist()
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        startTrack(at: i)
    }

    func remove(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        queue.remove(at: i)
        if let cur = index, i < cur { index = cur - 1 }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        guard let cur = index else { return }
        // Every move happens inside Up Next, so the current position stays.
        guard source.allSatisfy({ $0 > cur }), destination > cur else { return }
        queue.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func clearUpNext() {
        guard let i = index else { return }
        queue.removeSubrange((i + 1)...)
        radioToken = nil
        persist()
    }

    // MARK: Transport

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        guard let t = current else { return }
        if loadedId != t.videoId {
            load(t, start: pendingStart)
        } else {
            engine.play()
        }
    }

    func pause() { engine.pause() }

    func next() {
        guard let i = index else { return }
        if i + 1 < queue.count { startTrack(at: i + 1) }
        else if repeatMode == .all, !queue.isEmpty { startTrack(at: 0) }
        else if autoplay, let last = current {
            let mine = epoch
            Task {
                await fillRadio(seed: last, replaceUpcoming: false).value
                guard epoch == mine, let j = index, j + 1 < queue.count else { return }
                startTrack(at: j + 1)
            }
        }
    }

    func previous() {
        guard let i = index else { return }
        if time() > 3 || i == 0 { seek(to: 0) } else { startTrack(at: i - 1) }
    }

    func seek(to t: Double) {
        position = t
        positionStamp = .now
        if loadedId == current?.videoId { engine.seek(t) } else { pendingStart = t }
    }

    func toggleShuffle() {
        guard let i = index else { shuffled.toggle(); return }
        let cur = queue[i]
        if shuffled, let original = unshuffled {
            // Tracks added after shuffling (radio, Play Next) stay, after the original order.
            let originalIds = Set(original.map(\.videoId))
            let added = queue.filter { !originalIds.contains($0.videoId) }
            var restored = original + added
            if let j = restored.firstIndex(where: { $0.videoId == cur.videoId }) {
                restored[j] = cur
                queue = restored
                index = j
            }
            unshuffled = nil
            shuffled = false
        } else {
            unshuffled = queue
            var rest = Array(queue.dropFirst(i + 1))
            rest.shuffle()
            queue = Array(queue.prefix(i + 1)) + rest
            shuffled = true
        }
        persist()
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off }
    }

    func toggleLike() {
        guard let t = current else { return }
        let newValue = !(liked ?? false)
        liked = newValue
        Task {
            do { try await api.rate(t.videoId, like: newValue) }
            catch { liked = !newValue; self.error = error.localizedDescription }
        }
    }

    func like(_ t: Track, _ value: Bool) {
        if t.videoId == current?.videoId { liked = value }
        Task { try? await api.rate(t.videoId, like: value) }
    }

    // MARK: Internals

    private func startTrack(at i: Int) {
        index = i
        pendingStart = 0
        position = 0
        positionStamp = .now
        duration = queue[i].duration ?? 0
        liked = nil
        lyrics = nil
        error = nil
        load(queue[i], start: 0)
        persist()
    }

    private func load(_ t: Track, start: Double) {
        note("load \(t.videoId) \(t.title)")
        loadedId = t.videoId
        isBuffering = true
        isPlaying = true
        position = start
        positionStamp = .now
        pendingStart = 0
        metaSentFor = nil
        Task {
            await engine.load(videoId: t.videoId, start: start)
            engine.setVolume(volume)
        }
        trackTask?.cancel()
        trackTask = Task { await loadDetails(for: t) }
    }

    private func loadDetails(for t: Track) async {
        lyricsLoading = true
        let w = try? await api.watch(videoId: t.videoId, playlistId: nil)
        guard !Task.isCancelled, current?.videoId == t.videoId else { return }
        liked = w?.liked
        // Fill in what the list row did not carry (album, art, length).
        if let i = index, let rich = w?.tracks.first(where: { $0.videoId == t.videoId }) {
            var c = queue[i]
            if c.title.isEmpty || c.title == c.videoId { c.title = rich.title }
            if c.album == nil { c.album = rich.album }
            if c.duration == nil { c.duration = rich.duration }
            if c.artists.isEmpty { c.artists = rich.artists }
            if c.thumb == nil { c.thumb = rich.thumb }
            queue[i] = c
            sendMetadata()
        }
        let l = await LyricsService.fetch(track: current ?? t, api: api, lyricsBrowseId: w?.lyricsBrowseId)
        guard !Task.isCancelled, current?.videoId == t.videoId else { return }
        lyrics = l
        lyricsLoading = false
        // A lone track keeps going: queue a station behind it.
        if autoplay, let i = index, i == queue.count - 1, repeatMode == .off {
            fillRadio(seed: t, replaceUpcoming: false)
        }
    }

    /// Appends (or, for a fresh station, replaces) upcoming tracks with radio.
    /// One fill per queue at a time; callers can await the returned task.
    @discardableResult
    private func fillRadio(seed: Track, replaceUpcoming: Bool) -> Task<Void, Never> {
        if let f = fillTask, fillEpoch == epoch, !replaceUpcoming { return f }
        fillTask?.cancel()
        let mine = epoch
        fillId += 1
        let id = fillId
        fillEpoch = mine
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.fillId == id { self.fillTask = nil } }
            do {
                var tracks: [Track]
                var token: String?
                if let t = self.radioToken, !replaceUpcoming {
                    (tracks, token) = try await self.api.watchMore(t)
                } else {
                    let w = try await self.api.watch(videoId: seed.videoId, playlistId: nil, radio: true)
                    tracks = w.tracks
                    token = w.continuation
                }
                guard !Task.isCancelled, self.epoch == mine, let i = self.index else { return }
                self.radioToken = token
                let known = Set(self.queue.map(\.videoId))
                tracks.removeAll { known.contains($0.videoId) }
                if replaceUpcoming { self.queue.removeSubrange((i + 1)...) }
                self.queue += tracks
                self.persist()
            } catch {
                if self.epoch == mine, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        fillTask = task
        return task
    }

    private func handle(_ e: WebEngine.Event) {
        switch e {
        case .ready:
            engine.setVolume(volume)
            metaSentFor = nil
        case let .progress(time, dur, paused, buffering, ad, videoId):
            isAd = ad
            if ad {
                isPlaying = !paused
                return
            }
            if let videoId, videoId != current?.videoId { return }
            if metaSentFor != current?.videoId { sendMetadata() }
            position = time
            positionStamp = .now
            if dur > 0 { duration = dur }
            if isPlaying != !paused { note(paused ? "page paused at \(Int(time))" : "page playing at \(Int(time))") }
            isPlaying = !paused
            isBuffering = buffering
        case .ended(let videoId):
            note("ended \(videoId ?? "?")")
            guard videoId == nil || videoId == current?.videoId else { return }
            // A pre-roll ad can report its end against the song; a real end is near the song's length.
            guard duration <= 0 || position > duration - 8 else { note("ignored early end at \(Int(position))"); return }
            // The page holds nothing now; Play after the queue's end starts the track again.
            loadedId = nil
            pendingStart = 0
            if repeatMode == .one, let t = current { load(t, start: 0) } else { next() }
        case .pageLost:
            // The page reloaded (crash, sign-in, sign-out): the track must be loaded again.
            if loadedId != nil { pendingStart = time() }
            loadedId = nil
            isPlaying = false
            isBuffering = false
        case let .remote(action, t):
            note("remote \(action)")
            switch action {
            case "play": resume()
            case "pause": pause()
            case "nexttrack": next()
            case "previoustrack": previous()
            case "seekto": if let t { seek(to: t) }
            default: break
            }
        case .failed(let message):
            error = message
        }
    }

    private func sendMetadata() {
        guard let t = current else { return }
        metaSentFor = t.videoId
        engine.setMetadata(title: t.title, artist: t.artistLine, album: t.album?.name, art: t.thumb?.sized(544))
    }

    // MARK: Persistence

    private struct Saved: Codable { var queue: [Track]; var index: Int?; var position: Double }

    private func persist() {
        // Keep at most 500 tracks, always a window that contains the current one.
        let i = index ?? 0
        let lo = max(0, min(i, queue.count - 500))
        let hi = min(queue.count, lo + 500)
        let s = Saved(queue: Array(queue[lo..<hi]), index: index.map { $0 - lo }, position: time())
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "session") }
    }

    func persistPosition() { persist() }

    private func restore() {
        guard let d = UserDefaults.standard.data(forKey: "session"),
              let s = try? JSONDecoder().decode(Saved.self, from: d),
              let i = s.index, s.queue.indices.contains(i) else { return }
        queue = s.queue
        index = i
        position = s.position
        pendingStart = s.position
        duration = queue[i].duration ?? 0
        isPlaying = false
        trackTask = Task { await loadDetails(for: queue[i]) }
    }
}
