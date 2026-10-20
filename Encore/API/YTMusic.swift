import Foundation

/// Typed YouTube Music endpoints on top of the page transport.
@Observable
final class YTMusic {
    let engine: WebEngine

    init(engine: WebEngine) { self.engine = engine }

    enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists", videos = "Videos"
        var id: String { rawValue }
        var params: String? {
            switch self {
            case .all: nil
            case .songs: "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
            case .videos: "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
            case .albums: "EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D"
            case .artists: "EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D"
            case .playlists: "EgeKAQQoADgBagwQDhAKEAMQBRAJEAQ%3D"
            }
        }
    }

    func home() async throws -> [Shelf] {
        let root = try await engine.call("browse", ["browseId": "FEmusic_home"])
        var shelves = Parser.shelves(Parser.sectionList(root))
        // Home arrives in pages; two more keep the scroll full.
        var token = Parser.sectionContinuation(root)
        for _ in 0..<2 {
            guard let t = token else { break }
            let more = try await engine.call("browse", [:], query: "&ctoken=\(t)&continuation=\(t)&type=next")
            let sl = more["continuationContents"]["sectionListContinuation"]
            shelves += Parser.shelves(sl["contents"].array)
            token = sl["continuations"][0]["nextContinuationData"]["continuation"].string
        }
        return shelves
    }

    func search(_ q: String, filter: SearchFilter) async throws -> SearchResults {
        // "All" rows come without album or length; the Songs view has both.
        let richSongs = filter == .all ? Task { try? await self.search(q, filter: .songs) } : nil
        var body: [String: Any] = ["query": q]
        if let p = filter.params { body["params"] = p.removingPercentEncoding ?? p }
        var r = Parser.search(try await engine.call("search", body))
        if let rich = await richSongs?.value,
           let songs = rich.shelves.first(where: { $0.id == "songs" }),
           let i = r.shelves.firstIndex(where: { $0.id == "songs" }),
           case .tracks(let t) = songs.content {
            r.shelves[i].content = .tracks(Array(t.prefix(8)))
        }
        return r
    }

    func suggestions(_ q: String) async throws -> [String] {
        Parser.suggestions(try await engine.call("music/get_search_suggestions", ["input": q]))
    }

    func collection(_ browseId: String) async throws -> CollectionPage {
        let root = try await engine.call("browse", ["browseId": browseId])
        return Parser.collection(root, browseId: browseId)
    }

    func more(_ c: Continuation, page: CollectionPage) async throws -> ([Track], Continuation?) {
        let root: J
        switch c {
        case .token(let t): root = try await engine.call("browse", ["continuation": t])
        case .legacy(let t): root = try await engine.call("browse", [:], query: "&ctoken=\(t)&continuation=\(t)&type=next")
        }
        let album = page.kind == .album ? page.tracks.first?.album : nil
        return Parser.continuationItems(root, fallbackArtists: page.artists, fallbackAlbum: album,
                                        fallbackThumb: page.kind == .album ? page.thumb : nil)
    }

    /// Every track of a collection, following continuations (for Play/Shuffle).
    func allTracks(of page: CollectionPage, limit: Int = 1000) async -> [Track] {
        var tracks = page.tracks
        var next = page.continuation
        while let c = next, tracks.count < limit {
            guard let r = try? await more(c, page: page) else { break }
            tracks += r.0
            next = r.1
        }
        return tracks
    }

    func artist(_ browseId: String) async throws -> ArtistPage {
        Parser.artist(try await engine.call("browse", ["browseId": browseId]))
    }

    struct WatchInfo {
        var tracks: [Track]
        var continuation: String?
        var lyricsBrowseId: String?
        var liked: Bool?
    }

    /// Up-next / radio for a track or playlist.
    func watch(videoId: String?, playlistId: String?, radio: Bool = false, shuffle: Bool = false) async throws -> WatchInfo {
        var body: [String: Any] = ["isAudioOnly": true, "enablePersistentPlaylistPanel": true, "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"]
        if let videoId { body["videoId"] = videoId }
        if let playlistId { body["playlistId"] = playlistId }
        else if radio, let videoId { body["playlistId"] = "RDAMVM" + videoId }
        if radio { body["params"] = "wAEB" }
        if shuffle { body["params"] = "wAEB8gECKAE%3D".removingPercentEncoding! }
        return parseWatch(try await engine.call("next", body))
    }

    func watchMore(_ token: String) async throws -> ([Track], String?) {
        let root = try await engine.call("next", ["enablePersistentPlaylistPanel": true, "isAudioOnly": true],
                                         query: "&ctoken=\(token)&continuation=\(token)&type=next")
        let c = root["continuationContents"]["playlistPanelContinuation"]
        return (c["contents"].array.compactMap(Parser.queueTrack),
                c["continuations"][0].any("nextRadioContinuationData", "nextContinuationData")["continuation"].string)
    }

    private func parseWatch(_ root: J) -> WatchInfo {
        let tabs = root["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]["tabs"]
        let panel = tabs[0]["tabRenderer"]["content"]["musicQueueRenderer"]["content"]["playlistPanelRenderer"]
        let lyrics = tabs.array.first { $0["tabRenderer"]["endpoint"]["browseEndpoint"]["browseId"].string?.hasPrefix("MPLY") == true }
        var liked: Bool?
        for a in root["playerOverlays"]["playerOverlayRenderer"]["actions"].array {
            if let s = a["likeButtonRenderer"]["likeStatus"].string { liked = s == "LIKE" }
        }
        return WatchInfo(
            tracks: panel["contents"].array.compactMap(Parser.queueTrack),
            continuation: panel["continuations"][0].any("nextRadioContinuationData", "nextContinuationData")["continuation"].string,
            lyricsBrowseId: lyrics?["tabRenderer"]["endpoint"]["browseEndpoint"]["browseId"].string,
            liked: liked)
    }

    func plainLyrics(_ browseId: String) async throws -> (text: String, source: String?)? {
        let root = try await engine.call("browse", ["browseId": browseId])
        let shelf = root["contents"]["sectionListRenderer"]["contents"][0]["musicDescriptionShelfRenderer"]
        guard let text = shelf["description"].text else { return nil }
        return (text, shelf["footer"].text)
    }

    func rate(_ videoId: String, like: Bool) async throws {
        _ = try await engine.call(like ? "like/like" : "like/removelike", ["target": ["videoId": videoId]], retry: false)
    }

    // MARK: Library

    func likedSongs() async throws -> CollectionPage { try await collection("VLLM") }

    func libraryCards(_ browseId: String) async throws -> [Card] {
        let root = try await engine.call("browse", ["browseId": browseId])
        return Parser.shelves(Parser.sectionList(root)).flatMap { s -> [Card] in
            if case .cards(let c) = s.content { return c }
            return []
        }
    }

    func history() async throws -> [Shelf] {
        Parser.shelves(Parser.sectionList(try await engine.call("browse", ["browseId": "FEmusic_history"])))
    }

    struct Account { var name: String; var handle: String?; var photo: Thumb? }

    func account() async throws -> Account? {
        let root = try await engine.call("account/account_menu", [:])
        let h = root["actions"][0]["openPopupAction"]["popup"]["multiPageMenuRenderer"]["header"]["activeAccountHeaderRenderer"]
        guard let name = h["accountName"].text else { return nil }
        return Account(name: name, handle: h["channelHandle"].text, photo: Parser.thumb(h["accountPhoto"]))
    }

    func addToPlaylist(_ playlistId: String, videoId: String) async throws {
        _ = try await engine.call("browse/edit_playlist", ["playlistId": playlistId, "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]]], retry: false)
    }
}
