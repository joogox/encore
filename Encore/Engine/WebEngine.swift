import AppKit
import OSLog
import WebKit

/// The hidden music.youtube.com page. It is Encore's audio engine and its
/// API transport: InnerTube calls run inside the page, so they carry the
/// page's own cookies, client version and visitor data.
@Observable
final class WebEngine: NSObject {
    enum Event {
        case ready(loggedIn: Bool)
        case progress(time: Double, duration: Double, paused: Bool, buffering: Bool, ad: Bool, videoId: String?)
        case ended(videoId: String?)
        case remote(action: String, time: Double?)
        case failed(String)
        case pageLost
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"
    static let home = URL(string: "https://music.youtube.com/")!

    private(set) var isReady = false
    private(set) var isLoggedIn = false
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Encore", category: "engine")
    private func note(_ s: String) { Self.logger.debug("\(s)") }
    var onEvent: ((Event) -> Void)?

    let webView: WKWebView
    private var host: NSWindow?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = false
        let bridge = Bundle.main.url(forResource: "bridge", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        config.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), configuration: config)
        webView.customUserAgent = Self.userAgent

        super.init()
        keepVisible()
        config.userContentController.add(WeakHandler(self), name: "encore")
        webView.navigationDelegate = self
    }

    /// Called once the app has finished launching. An off-screen but real
    /// window keeps the page alive and audible whether or not Encore's own
    /// windows are open. (Created any earlier, SwiftUI treats it as the
    /// launch window and skips the main one.)
    func start() {
        guard host == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 400),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.alphaValue = 0
        w.isExcludedFromWindowsMenu = true
        w.contentView = webView
        w.orderBack(nil)
        host = w
        Task {
            await ensureConsentChoice()
            webView.load(URLRequest(url: Self.home))
        }
    }

    /// In the EU YouTube first shows a cookie wall. `SOCS=CAI` is the
    /// "reject all non-essential" answer, so nothing beyond the session is set.
    private func ensureConsentChoice() async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        // CAI = rejected, CAES… = a choice made by the user; anything else
        // (the wall's own "undecided" value) is replaced.
        let decided = cookies.contains { $0.name == "SOCS" && $0.domain.hasSuffix("youtube.com") && ($0.value == "CAI" || $0.value.hasPrefix("CAES")) }
        guard !decided else { return }
        for c in cookies where c.name == "SOCS" { await store.deleteCookie(c) }
        let props: [HTTPCookiePropertyKey: Any] = [
            .name: "SOCS", .value: "CAI", .domain: ".youtube.com", .path: "/", .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 390),
        ]
        if let c = HTTPCookie(properties: props) { await store.setCookie(c) }
    }

    /// The player window is never on screen, so WebKit would mark the page
    /// hidden and YouTube stalls ads and throttles the player. WebKit's own
    /// switch (used by browsers with background windows) keeps it visible.
    private func keepVisible() {
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: sel), let imp = webView.method(for: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: Fn.self)(webView, sel, false)
    }

    func reload() {
        isReady = false
        onEvent?(.pageLost)
        webView.load(URLRequest(url: Self.home))
    }

    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    // MARK: API

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A call can be lost when the page navigates underneath it (sign-in,
    /// consent, a replaced player page), so each attempt is time-boxed and
    /// retried once the page is ready again.
    func call(_ endpoint: String, _ body: [String: Any], query: String = "", retry: Bool = true) async throws -> J {
        var lastError: Error = APIError(message: "YouTube Music did not answer")
        // Writes (likes, playlist edits) are not retried: a slow success would repeat.
        for attempt in 0..<(retry ? 3 : 1) {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(600 * attempt)) }
            note("\(endpoint) wait ready=\(isReady) try \(attempt)")
            await waitUntilReady()
            note("\(endpoint) send \(body["browseId"] ?? body["videoId"] ?? "")")
            do {
                return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<J, Error>) in
                    let once = Once()
                    Task {
                        do { let r = try await self.callOnce(endpoint, body, query: query); self.note("\(endpoint) ok"); if once.claim() { cont.resume(returning: r) } }
                        catch { if once.claim() { cont.resume(throwing: error) } }
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(15))
                        self.note("\(endpoint) timer fired")
                        if once.claim() { cont.resume(throwing: APIError(message: "YouTube Music took too long to answer")) }
                    }
                }
            } catch let e as APIError where e.message.contains("answered 4") {
                throw e
            } catch {
                note("\(endpoint) failed: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    private func callOnce(_ endpoint: String, _ body: [String: Any], query: String) async throws -> J {
        let result = try await webView.callAsyncJavaScript(
            "return await window.__encore.api(endpoint, body, query)",
            arguments: ["endpoint": endpoint, "body": body, "query": query],
            in: nil, contentWorld: .page)
        guard let dict = result as? [String: Any],
              let status = dict["status"] as? Int,
              let text = dict["text"] as? String else {
            throw APIError(message: "No response from YouTube Music")
        }
        guard status == 200 else {
            throw APIError(message: "YouTube Music answered \(status) for \(endpoint)")
        }
        return try J(data: Data(text.utf8))
    }

    // MARK: Player

    private var latestLoad: String?

    func load(videoId: String, start: Double = 0) async {
        latestLoad = videoId
        await waitUntilReady()
        guard latestLoad == videoId else { return }
        let how = (try? await webView.callAsyncJavaScript(
            "return window.__encore.load(id, start)", arguments: ["id": videoId, "start": start],
            in: nil, contentWorld: .page)) as? String
        if how == "replace" {
            // The page reloads; the fresh bridge must know what it is playing.
            isReady = false
            await waitUntilReady()
            guard latestLoad == videoId else { return }
            _ = try? await webView.callAsyncJavaScript("window.__encore.expect(id)", arguments: ["id": videoId], in: nil, contentWorld: .page)
        }
    }

    func play() { run("window.__encore.play()") }
    func pause() { run("window.__encore.pause()") }
    func seek(_ t: Double) { run("window.__encore.seek(\(t))") }
    func setVolume(_ v: Double) { run("window.__encore.volume(\(max(0, min(1, v))))") }
    func skipAd() { run("window.__encore.skipAd()") }

    func setMetadata(title: String, artist: String, album: String?, art: URL?) {
        let m: [String: Any] = ["title": title, "artist": artist, "album": album ?? "", "art": art?.absoluteString ?? ""]
        Task { _ = try? await webView.callAsyncJavaScript("window.__encore.setMeta(m)", arguments: ["m": m], in: nil, contentWorld: .page) }
    }

    private func run(_ js: String) {
        guard isReady else { return }
        webView.evaluateJavaScript(js, in: nil, in: .page) { _ in }
    }

    // MARK: Messages

    fileprivate func receive(_ body: Any) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            isLoggedIn = m["loggedIn"] as? Bool ?? false
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0.resume() }
            onEvent?(.ready(loggedIn: isLoggedIn))
        case "time", "state":
            onEvent?(.progress(
                time: m["time"] as? Double ?? 0,
                duration: m["duration"] as? Double ?? 0,
                paused: m["paused"] as? Bool ?? true,
                buffering: m["buffering"] as? Bool ?? false,
                ad: m["ad"] as? Bool ?? false,
                videoId: m["videoId"] as? String))
        case "ended":
            onEvent?(.ended(videoId: m["videoId"] as? String))
        case "remote":
            onEvent?(.remote(action: m["action"] as? String ?? "", time: m["time"] as? Double))
        case "error":
            onEvent?(.failed(m["message"] as? String ?? "Playback error"))
        case "log":
            note(m["message"] as? String ?? "")
        default: break
        }
    }
}

extension WebEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.host?.hasPrefix("consent.") == true {
            Task { await ensureConsentChoice(); reload() }
        }
    }

    /// Cancelled or superseded navigations (a page replaced twice) are not failures.
    private func isBenign(_ error: Error) -> Bool {
        let e = error as NSError
        return (e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled) || (e.domain == "WebKitErrorDomain" && e.code == 102)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isBenign(error) else { return }
        onEvent?(.failed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isBenign(error) else { return }
        onEvent?(.failed(error.localizedDescription))
        // Retry once the network is back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.reload() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }
}

private final class Once {
    private var done = false
    func claim() -> Bool { if done { return false }; done = true; return true }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var engine: WebEngine?
    init(_ engine: WebEngine) { self.engine = engine }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        engine?.receive(message.body)
    }
}
