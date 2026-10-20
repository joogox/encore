import Foundation

/// Turns InnerTube renderers into Encore's models. Paths follow live
/// WEB_REMIX responses.
enum Parser {

    // MARK: - Small pieces

    static func pageKind(_ pageType: String?) -> PageKind {
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK": return .album
        case "MUSIC_PAGE_TYPE_PLAYLIST": return .playlist
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST": return .artist
        default: return .other
        }
    }

    static func destination(_ nav: J, title: String = "") -> Destination? {
        let b = nav["browseEndpoint"]
        guard let id = b["browseId"].string else { return nil }
        let pt = b["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string
        var kind = pageKind(pt)
        if kind == .other {
            if id.hasPrefix("MPRE") { kind = .album }
            else if id.hasPrefix("VL") { kind = .playlist }
            else if id.hasPrefix("UC") { kind = .artist }
        }
        return Destination(browseId: id, kind: kind, title: title)
    }

    static func thumb(_ j: J) -> Thumb? {
        let list = j.any("musicThumbnailRenderer", "croppedSquareThumbnailRenderer")["thumbnail"]["thumbnails"]
        let candidates = list.exists ? list : j["thumbnails"]
        guard let url = candidates.last["url"].string else { return nil }
        return Thumb(url: url)
    }

    static func duration(_ s: String?) -> TimeInterval? {
        guard let s, s.range(of: #"^\d+(:\d{2}){1,2}$"#, options: .regularExpression) != nil else { return nil }
        return s.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    private static let typeLabels: Set<String> = [
        "Song", "Video", "Episode", "Album", "Single", "EP", "Playlist", "Artist",
        "Profile", "Podcast", "Audiobook", "Station",
    ]

    /// Splits a byline into ` • `-separated segments of runs.
    static func segments(_ runs: [J]) -> [[J]] {
        var out: [[J]] = [[]]
        for r in runs {
            if r["text"].string?.trimmingCharacters(in: .whitespaces) == "•" { out.append([]) }
            else { out[out.count - 1].append(r) }
        }
        return out.filter { !$0.isEmpty }
    }

    static func artists(in segment: [J]) -> [ArtistRef] {
        segment.compactMap { r in
            guard let t = r["text"].string?.trimmingCharacters(in: .whitespaces),
                  !t.isEmpty, t != "&", t != ",", t != "x" else { return nil }
            let d = destination(r["navigationEndpoint"])
            if let d, d.kind != .artist { return nil }
            return ArtistRef(name: t, id: d?.browseId)
        }
    }

    private static func looksLikeStat(_ s: String) -> Bool {
        s.range(of: #"(views|plays|subscribers|monthly audience|songs|listeners)$"#, options: .regularExpression) != nil
            || duration(s) != nil
            || s.range(of: #"^\d{4}$"#, options: .regularExpression) != nil
    }

    /// Reads artists/album/duration out of a byline that may or may not
    /// start with a type label ("Song • Radiohead • Album • 4:30").
    static func byline(_ runs: [J]) -> (type: String?, artists: [ArtistRef], album: AlbumRef?, duration: TimeInterval?) {
        var type: String?
        var artists: [ArtistRef] = []
        var album: AlbumRef?
        var dur: TimeInterval?
        for (i, seg) in segments(runs).enumerated() {
            let joined = seg.compactMap { $0["text"].string }.joined().trimmingCharacters(in: .whitespaces)
            if i == 0, typeLabels.contains(joined) { type = joined; continue }
            if let d = duration(joined) { dur = d; continue }
            if let a = seg.first(where: { destination($0["navigationEndpoint"])?.kind == .album }),
               let id = destination(a["navigationEndpoint"])?.browseId {
                album = AlbumRef(name: a["text"].string ?? "", id: id)
                continue
            }
            if artists.isEmpty, !looksLikeStat(joined) {
                artists = Self.artists(in: seg)
            }
        }
        return (type, artists, album, dur)
    }

    // MARK: - Tracks

    static func watchVideoId(_ nav: J) -> String? { nav["watchEndpoint"]["videoId"].string }

    static func isVideoType(_ nav: J) -> Bool {
        let t = nav["watchEndpoint"]["watchEndpointMusicSupportedConfigs"]["watchEndpointMusicConfig"]["musicVideoType"].string
        return t != nil && t != "MUSIC_VIDEO_TYPE_ATV"
    }

    /// A `musicResponsiveListItemRenderer` that plays something.
    static func track(_ r: J, fallbackArtists: [ArtistRef] = [], fallbackAlbum: AlbumRef? = nil, fallbackThumb: Thumb? = nil) -> Track? {
        let flex = r["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
        let titleRun = flex.first?.runs.first ?? J(nil)
        let overlayNav = r["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]
        guard let videoId = r["playlistItemData"]["videoId"].string
                ?? watchVideoId(titleRun["navigationEndpoint"])
                ?? watchVideoId(overlayNav) else { return nil }

        var artists: [ArtistRef] = []
        var album: AlbumRef?
        var dur: TimeInterval?
        for col in flex.dropFirst() {
            let b = byline(col.runs)
            if artists.isEmpty { artists = b.artists }
            if album == nil { album = b.album }
            if dur == nil { dur = b.duration }
        }
        for fixed in r["fixedColumns"].array {
            if dur == nil { dur = duration(fixed["musicResponsiveListItemFixedColumnRenderer"]["text"].text) }
        }
        let nav = titleRun["navigationEndpoint"].exists ? titleRun["navigationEndpoint"] : overlayNav
        return Track(
            videoId: videoId,
            title: flex.first?.text ?? "",
            artists: artists.isEmpty ? fallbackArtists : artists,
            album: album ?? fallbackAlbum,
            duration: dur,
            thumb: thumb(r["thumbnail"]) ?? fallbackThumb,
            isVideo: isVideoType(nav),
            setVideoId: r["playlistItemData"]["playlistSetVideoId"].string
        )
    }

    /// Queue rows from the `next` endpoint.
    static func queueTrack(_ x: J) -> Track? {
        var r = x["playlistPanelVideoRenderer"]
        if !r.exists { r = x["playlistPanelVideoWrapperRenderer"]["primaryRenderer"]["playlistPanelVideoRenderer"] }
        guard r.exists, let vid = r["videoId"].string else { return nil }
        let b = byline(r["longBylineText"].runs)
        return Track(
            videoId: vid,
            title: r["title"].text ?? "",
            artists: b.artists,
            album: b.album,
            duration: duration(r["lengthText"].text),
            thumb: thumb(r["thumbnail"]),
            isVideo: isVideoType(r["navigationEndpoint"])
        )
    }

    // MARK: - Cards

    static func card(twoRow r: J) -> Card? {
        let title = r["title"].text ?? ""
        let sub = r["subtitle"].text ?? ""
        let th = thumb(r["thumbnailRenderer"])
        let nav = r["navigationEndpoint"]
        let wide = r["aspectRatio"].string?.contains("16_9") ?? false
        if let d = destination(nav, title: title) {
            return Card(id: d.browseId, title: title, subtitle: sub, thumb: th, action: .open(d),
                        wide: wide, round: d.kind == .artist)
        }
        if let vid = watchVideoId(nav) {
            let b = byline(r["subtitle"].runs)
            let t = Track(videoId: vid, title: title, artists: b.artists, album: b.album, duration: nil, thumb: th, isVideo: isVideoType(nav))
            return Card(id: vid, title: title, subtitle: sub, thumb: th, action: .play(t), wide: wide)
        }
        if let pl = nav["watchPlaylistEndpoint"]["playlistId"].string {
            return Card(id: pl, title: title, subtitle: sub, thumb: th, action: .playlist(pl), wide: wide)
        }
        return nil
    }

    /// A list row that opens a page (search results, library artists).
    static func card(responsive r: J) -> Card? {
        let flex = r["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
        guard let d = destination(r["navigationEndpoint"], title: flex.first?.text ?? "") else { return nil }
        let sub = flex.dropFirst().compactMap(\.text).joined(separator: " • ")
        return Card(id: d.browseId, title: d.title, subtitle: sub, thumb: thumb(r["thumbnail"]),
                    action: .open(d), round: d.kind == .artist)
    }

    static func item(_ x: J) -> (track: Track?, card: Card?) {
        if x["musicTwoRowItemRenderer"].exists { return (nil, card(twoRow: x["musicTwoRowItemRenderer"])) }
        let r = x["musicResponsiveListItemRenderer"]
        guard r.exists else { return (nil, nil) }
        if let t = track(r) { return (t, nil) }
        return (nil, card(responsive: r))
    }

    // MARK: - Shelves

    static func shelves(_ sections: [J]) -> [Shelf] {
        var out: [Shelf] = []
        for (i, s) in sections.enumerated() {
            if s["itemSectionRenderer"].exists {
                out += shelves(s["itemSectionRenderer"]["contents"].array)
                continue
            }
            let r = s.any("musicCarouselShelfRenderer", "musicShelfRenderer", "musicPlaylistShelfRenderer", "gridRenderer", "musicImmersiveCarouselShelfRenderer")
            guard r.exists else { continue }
            let header = r["header"].any("musicCarouselShelfBasicHeaderRenderer", "gridHeaderRenderer", "musicImmersiveCarouselShelfBasicHeaderRenderer")
            let titleJ = r["title"].exists ? r["title"] : header["title"]
            let title = titleJ.text ?? ""
            let more = destination(titleJ.runs.first?["navigationEndpoint"] ?? J(nil), title: title)
            let items = (r["contents"].exists ? r["contents"] : r["items"]).array.map(item)
            let tracks = items.compactMap(\.track)
            let cards = items.compactMap(\.card)
            guard !tracks.isEmpty || !cards.isEmpty else { continue }
            let content: Shelf.Content = tracks.count >= cards.count ? .tracks(tracks) : .cards(cards)
            out.append(Shelf(id: "\(i)-\(title)", title: title, more: more, content: content))
        }
        return out
    }

    static func sectionList(_ root: J) -> [J] {
        let c = root["contents"]
        if c["singleColumnBrowseResultsRenderer"].exists {
            return c["singleColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array
        }
        if c["tabbedSearchResultsRenderer"].exists {
            return c["tabbedSearchResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array
        }
        if c["twoColumnBrowseResultsRenderer"].exists {
            let t = c["twoColumnBrowseResultsRenderer"]
            return t["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array
                + t["secondaryContents"]["sectionListRenderer"]["contents"].array
        }
        return c["sectionListRenderer"]["contents"].array
    }

    static func sectionContinuation(_ root: J) -> String? {
        root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["continuations"][0]["nextContinuationData"]["continuation"].string
    }

    // MARK: - Pages

    static func collection(_ root: J, browseId: String) -> CollectionPage {
        let two = root["contents"]["twoColumnBrowseResultsRenderer"]
        let primary = two["tabs"][0]["tabRenderer"]["content"]["sectionListRenderer"]["contents"][0]
        var h = primary["musicResponsiveHeaderRenderer"]
        if !h.exists { h = primary["musicEditablePlaylistDetailHeaderRenderer"]["header"]["musicResponsiveHeaderRenderer"] }
        if !h.exists { h = root["header"].any("musicDetailHeaderRenderer", "musicResponsiveHeaderRenderer") }

        let title = h["title"].text ?? ""
        let artists = Self.artists(in: h["straplineTextOne"].runs)
        let pageThumb = thumb(h["thumbnail"])
        let isAlbum = browseId.hasPrefix("MPRE")
        let albumRef = isAlbum ? AlbumRef(name: title, id: browseId) : nil
        let desc = h["description"]["musicDescriptionShelfRenderer"]["description"].text

        let shelf = two["secondaryContents"]["sectionListRenderer"]["contents"][0].any("musicShelfRenderer", "musicPlaylistShelfRenderer")
        var items = shelf["contents"].array
        var cont: Continuation?
        if let last = items.last, last["continuationItemRenderer"].exists {
            cont = last["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"].string.map(Continuation.token)
            items.removeLast()
        } else if let c = shelf["continuations"][0]["nextContinuationData"]["continuation"].string {
            cont = .legacy(c)
        }
        let tracks = items.compactMap {
            track($0["musicResponsiveListItemRenderer"], fallbackArtists: artists, fallbackAlbum: albumRef,
                  fallbackThumb: isAlbum ? pageThumb : nil)
        }

        var playlistId: String? = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : nil
        for b in h["buttons"].array {
            if let p = b["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchPlaylistEndpoint"]["playlistId"].string { playlistId = p }
        }
        if playlistId == nil { playlistId = shelf["playlistId"].string }

        return CollectionPage(
            title: title,
            subtitle: h["subtitle"].text ?? "",
            detail: h["secondSubtitle"].text ?? "",
            description: desc,
            thumb: pageThumb ?? tracks.first?.thumb,
            artists: artists,
            tracks: tracks,
            playlistId: playlistId,
            continuation: cont,
            kind: isAlbum ? .album : .playlist
        )
    }

    /// Items and the next token from a continuation response, either style.
    static func continuationItems(_ root: J, fallbackArtists: [ArtistRef], fallbackAlbum: AlbumRef?, fallbackThumb: Thumb?) -> ([Track], Continuation?) {
        var items: [J] = []
        var next: Continuation?
        let action = root["onResponseReceivedActions"][0]["appendContinuationItemsAction"]["continuationItems"]
        if action.exists {
            items = action.array
            if let last = items.last, last["continuationItemRenderer"].exists {
                next = last["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"].string.map(Continuation.token)
                items.removeLast()
            }
        } else {
            let c = root["continuationContents"].any("musicPlaylistShelfContinuation", "musicShelfContinuation")
            items = c["contents"].array
            next = c["continuations"][0]["nextContinuationData"]["continuation"].string.map(Continuation.legacy)
        }
        let tracks = items.compactMap {
            track($0["musicResponsiveListItemRenderer"], fallbackArtists: fallbackArtists, fallbackAlbum: fallbackAlbum, fallbackThumb: fallbackThumb)
        }
        return (tracks, next)
    }

    static func artist(_ root: J) -> ArtistPage {
        let h = root["header"].any("musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer", "musicHeaderRenderer")
        let radioNav = h["startRadioButton"]["buttonRenderer"]["navigationEndpoint"]["watchEndpoint"]
        let shuffleNav = h["playButton"]["buttonRenderer"]["navigationEndpoint"]["watchEndpoint"]
        var radio: (String?, String)?
        if let pl = radioNav["playlistId"].string { radio = (radioNav["videoId"].string, pl) }
        let sections = sectionList(root)
        let desc = sections.first { $0["musicDescriptionShelfRenderer"].exists }?["musicDescriptionShelfRenderer"]["description"].text
        return ArtistPage(
            name: h["title"].text ?? "",
            banner: thumb(h["thumbnail"]) ?? thumb(h["foregroundThumbnail"]),
            listeners: h["monthlyListenerCount"].text ?? h["subscriptionButton"]["subscribeButtonRenderer"]["subscriberCountText"].text,
            description: desc ?? h["description"].text,
            radio: radio,
            shuffle: shuffleNav["playlistId"].string,
            shelves: shelves(sections)
        )
    }

    // MARK: - Search

    static func search(_ root: J) -> SearchResults {
        let sections = sectionList(root)
        var top: Card?
        var topTracks: [Track] = []
        var songs: [Track] = [], videos: [Track] = []
        var albums: [Card] = [], artists: [Card] = [], playlists: [Card] = []
        var shelvesOut: [Shelf] = []

        func sort(_ x: J) {
            let r = x["musicResponsiveListItemRenderer"]
            guard r.exists else { return }
            let flex = r["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
            let type = flex.count > 1 ? byline(flex[1].runs).type : nil
            if let t = track(r) {
                if type == "Episode" { return }
                if t.isVideo || type == "Video" { videos.append(t) } else { songs.append(t) }
            } else if let c = card(responsive: r), case .open(let d) = c.action {
                switch d.kind {
                case .album: albums.append(c)
                case .artist where type != "Profile": artists.append(c)
                case .playlist: playlists.append(c)
                default: break
                }
            }
        }

        for s in sections {
            let card = s["musicCardShelfRenderer"]
            if card.exists {
                let t = card["title"]
                let nav = t.runs.first?["navigationEndpoint"] ?? J(nil)
                let th = thumb(card["thumbnail"])
                if let d = destination(nav, title: t.text ?? "") {
                    top = Card(id: d.browseId, title: d.title, subtitle: card["subtitle"].text ?? "", thumb: th,
                               action: .open(d), round: d.kind == .artist)
                } else if let vid = watchVideoId(nav) ?? watchVideoId(card["onTap"]) {
                    let b = byline(card["subtitle"].runs)
                    let tr = Track(videoId: vid, title: t.text ?? "", artists: b.artists, album: b.album, duration: b.duration, thumb: th)
                    top = Card(id: vid, title: tr.title, subtitle: card["subtitle"].text ?? "", thumb: th, action: .play(tr))
                }
                let fallback = top.flatMap { c -> [ArtistRef]? in
                    if case .open(let d) = c.action, d.kind == .artist { return [ArtistRef(name: d.title, id: d.browseId)] }
                    return nil
                } ?? []
                topTracks = card["contents"].array.compactMap {
                    track($0["musicResponsiveListItemRenderer"], fallbackArtists: fallback)
                }
                continue
            }
            if s["musicShelfRenderer"].exists {
                s["musicShelfRenderer"]["contents"].array.forEach(sort)
            }
            for x in s["itemSectionRenderer"]["contents"].array {
                if x["musicShelfRenderer"].exists { x["musicShelfRenderer"]["contents"].array.forEach(sort) } else { sort(x) }
            }
        }
        if !songs.isEmpty { shelvesOut.append(Shelf(id: "songs", title: "Songs", content: .tracks(songs))) }
        if !artists.isEmpty { shelvesOut.append(Shelf(id: "artists", title: "Artists", content: .cards(artists))) }
        if !albums.isEmpty { shelvesOut.append(Shelf(id: "albums", title: "Albums", content: .cards(albums))) }
        if !playlists.isEmpty { shelvesOut.append(Shelf(id: "playlists", title: "Playlists", content: .cards(playlists))) }
        if !videos.isEmpty { shelvesOut.append(Shelf(id: "videos", title: "Videos", content: .tracks(videos))) }
        return SearchResults(top: top, topTracks: topTracks, shelves: shelvesOut)
    }

    static func suggestions(_ root: J) -> [String] {
        root["contents"][0]["searchSuggestionsSectionRenderer"]["contents"].array.compactMap {
            $0["searchSuggestionRenderer"]["suggestion"].text
        }
    }
}
