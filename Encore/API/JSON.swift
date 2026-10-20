import Foundation

/// A tolerant view over InnerTube's deeply nested JSON. Every lookup returns
/// another `J`; a missing key yields an empty `J` instead of crashing, so a
/// renderer path can be written in one line and fail soft.
struct J {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    init(data: Data) throws {
        raw = try JSONSerialization.jsonObject(with: data)
    }

    subscript(key: String) -> J { J((raw as? [String: Any])?[key]) }

    subscript(index: Int) -> J {
        guard let a = raw as? [Any], index >= 0, index < a.count else { return J(nil) }
        return J(a[index])
    }

    var exists: Bool { raw != nil && !(raw is NSNull) }
    var string: String? { raw as? String }
    var int: Int? { (raw as? NSNumber)?.intValue }
    var bool: Bool? { (raw as? NSNumber)?.boolValue }
    var array: [J] { (raw as? [Any])?.map(J.init) ?? [] }
    var dict: [String: Any] { raw as? [String: Any] ?? [:] }
    var keys: [String] { Array(dict.keys) }
    var last: J { array.last ?? J(nil) }

    /// First child under any of the given keys, e.g. a shelf that may arrive
    /// as `musicShelfRenderer` or `musicPlaylistShelfRenderer`.
    func any(_ keys: String...) -> J {
        for k in keys where self[k].exists { return self[k] }
        return J(nil)
    }

    /// Concatenated `runs[].text`, or `simpleText`.
    var text: String? {
        if let s = self["simpleText"].string { return s }
        let r = self["runs"].array.compactMap { $0["text"].string }
        return r.isEmpty ? nil : r.joined()
    }

    var runs: [J] { self["runs"].array }
}
