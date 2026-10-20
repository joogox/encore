import Foundation

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval?
    let text: String
}

struct Lyrics: Equatable {
    var lines: [LyricLine]
    var synced: Bool
    var source: String

    /// Index of the line being sung at `t`.
    func index(at t: TimeInterval) -> Int? {
        guard synced else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if let lt = lines[mid].time, lt <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

/// Time-synced lyrics from LRCLIB, YouTube Music's plain lyrics as fallback.
enum LyricsService {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": "Encore (https://github.com/joogox/encore)"]
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    private struct LRC: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?
        let duration: Double?
    }

    static func fetch(track: Track, api: YTMusic, lyricsBrowseId: String?) async -> Lyrics? {
        if let l = await lrclib(track) { return l }
        if let id = lyricsBrowseId, let plain = try? await api.plainLyrics(id) {
            let lines = plain.text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            return Lyrics(lines: lines.enumerated().map { LyricLine(id: $0, time: nil, text: $1) },
                          synced: false, source: plain.source ?? "YouTube Music")
        }
        return nil
    }

    private static func lrclib(_ t: Track) async -> Lyrics? {
        guard let artist = t.artists.first?.name else { return nil }
        let title = cleanTitle(t.title)
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let a = t.album?.name { c.queryItems?.append(URLQueryItem(name: "album_name", value: a)) }
        if let d = t.duration { c.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(d.rounded())))) }
        if let l = await decode(c.url) { return l }

        // Exact match missed (album naming differs): best search hit near the duration.
        var s = URLComponents(string: "https://lrclib.net/api/search")!
        s.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let url = s.url, let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let hits = try? JSONDecoder().decode([LRC].self, from: data) else { return nil }
        let synced = hits.filter { $0.syncedLyrics?.isEmpty == false }
        let best = synced.min { abs(($0.duration ?? 0) - (t.duration ?? 0)) < abs(($1.duration ?? 0) - (t.duration ?? 0)) }
        if let best, t.duration == nil || abs((best.duration ?? 0) - (t.duration ?? 0)) < 6 { return make(best) }
        return nil
    }

    private static func decode(_ url: URL?) async -> Lyrics? {
        guard let url, let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(LRC.self, from: data) else { return nil }
        return make(r)
    }

    private static func make(_ r: LRC) -> Lyrics? {
        if r.instrumental == true {
            return Lyrics(lines: [LyricLine(id: 0, time: nil, text: "Instrumental")], synced: false, source: "LRCLIB")
        }
        if let s = r.syncedLyrics, !s.isEmpty { return Lyrics(lines: parseLRC(s), synced: true, source: "LRCLIB") }
        if let p = r.plainLyrics, !p.isEmpty {
            return Lyrics(lines: p.components(separatedBy: "\n").enumerated().map { LyricLine(id: $0, time: nil, text: $1) },
                          synced: false, source: "LRCLIB")
        }
        return nil
    }

    static func parseLRC(_ s: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let rx = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in s.components(separatedBy: "\n") {
            let ns = raw as NSString
            let matches = rx.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let lastMatch = matches.last else { continue }
            let text = ns.substring(from: lastMatch.range.location + lastMatch.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let t = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60 + (Double(ns.substring(with: m.range(at: 2))) ?? 0)
                out.append(LyricLine(id: 0, time: t, text: text))
            }
        }
        out.sort { ($0.time ?? 0) < ($1.time ?? 0) }
        return out.enumerated().map { LyricLine(id: $0, time: $1.time, text: $1.text) }
    }

    /// "Song (Official Video) [Remastered]" → "Song"
    static func cleanTitle(_ s: String) -> String {
        var t = s
        for p in [#"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visualizer|remaster|hd|4k|mv)[^\)\]]*[\)\]]"#] {
            t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
