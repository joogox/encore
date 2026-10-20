import SwiftUI
import WebKit

/// Google's own sign-in page. Encore never sees the password; the session
/// cookies land in the store the player page shares.
struct SignInSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to YouTube Music").font(.headline)
                Spacer()
                Button("Cancel") { app.showSignIn = false }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            SignInWebView { app.signedIn() }
        }
        .frame(width: 520, height: 680)
    }
}

private struct SignInWebView: NSViewRepresentable {
    var done: () -> Void

    static let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Den%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F")!

    /// WKWebView cannot complete passkey ceremonies without a browser-only
    /// entitlement; hiding WebAuthn makes Google offer the password path.
    static let noPasskeys = """
    (() => {
      try { delete window.PublicKeyCredential; } catch (e) {}
      try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }); } catch (e) {}
      const c = navigator.credentials;
      if (c) {
        const wrap = (f) => function (o) {
          if (o && o.publicKey) return Promise.reject(new DOMException('Passkeys unavailable', 'NotAllowedError'));
          return f.apply(c, arguments);
        };
        try { c.get = wrap(c.get); c.create = wrap(c.create); } catch (e) {}
      }
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(WKUserScript(source: Self.noPasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let v = WKWebView(frame: .zero, configuration: config)
        v.customUserAgent = WebEngine.userAgent
        v.navigationDelegate = context.coordinator
        v.load(URLRequest(url: Self.url))
        return v
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let done: () -> Void
        private var finished = false
        init(done: @escaping () -> Void) { self.done = done }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, webView.url?.host?.contains("music.youtube.com") == true else { return }
            finished = true
            done()
        }
    }
}
