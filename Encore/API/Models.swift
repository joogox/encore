import Foundation

struct Thumb: Hashable, Codable {
    let url: String

    /// googleusercontent art carries its size in the URL (`=w60-h60-l90-rj`);
    /// rewriting it gives any resolution from one link.
    func sized(_ px: Int) -> URL? {
        var s = url
        if let r = s.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            s.replaceSubrange(r, with: "=w\(px)-h\(px)")
        } else if let r = s.range(of: #"=s\d+"#, options: .regularExpression) {
            s.replaceSubrange(r, with: "=s\(px)")
        }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }
}

struct ArtistRef: Hashable, Codable {
    let name: String
    let id: String?
}

struct AlbumRef: Hashable, Codable {
    let name: String
    let id: String
}

struct Track: Identifiable, Hashable, Codable {
    let videoId: String
    var title: String
    var artists: [ArtistRef]
    var album: AlbumRef?
    var duration: TimeInterval?
    var thumb: Thumb?
    var isVideo: Bool = false
    /// Present on playlist rows that the user owns (needed to remove them).
    var setVideoId: String? = nil

    var id: String { videoId }
    var artistLine: String { artists.map(\.name).joined(separator: ", ") }
}

enum PageKind: String, Codable, Hashable {
    case album, playlist, artist, other
}

/// Anything that opens a page: an album, playlist or artist.
struct Destination: Hashable, Codable {
    let browseId: String
    let kind: PageKind
    var title: String = ""
}

/// A tile in a carousel or grid.
struct Card: Identifiable, Hashable {
    enum Action: Hashable {
        case open(Destination)
        case play(Track)
        case playlist(String)
    }
    let id: String
    let title: String
    let subtitle: String
    let thumb: Thumb?
    let action: Action
    var wide: Bool = false
    var round: Bool = false
}

struct Shelf: Identifiable, Hashable {
    enum Content: Hashable {
        case cards([Card])
        case tracks([Track])
    }
    let id: String
    let title: String
    var more: Destination?
    var content: Content
}

struct CollectionPage {
    var title: String
    var subtitle: String
    var detail: String
    var description: String?
    var thumb: Thumb?
    var artists: [ArtistRef]
    var tracks: [Track]
    var playlistId: String?
    var continuation: Continuation?
    var kind: PageKind
}

struct ArtistPage {
    var name: String
    var banner: Thumb?
    var listeners: String?
    var description: String?
    var radio: (videoId: String?, playlistId: String)?
    var shuffle: String?
    var shelves: [Shelf]
}

struct SearchResults {
    var top: Card?
    var topTracks: [Track] = []
    var shelves: [Shelf]
}

enum Continuation: Hashable {
    /// New style: POST browse `{continuation: token}`.
    case token(String)
    /// Old style: `?ctoken=…&continuation=…&type=next`.
    case legacy(String)
}
