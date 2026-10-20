// Encore bridge: runs inside the hidden music.youtube.com page.
// Native owns the queue; this script plays exactly one track, reports
// progress, and carries API calls with the page's own session.
(() => {
  if (window.__encore) return;
  const post = (m) => { try { window.webkit.messageHandlers.encore.postMessage(m); } catch (e) {} };

  // ---- Media session: the page must not publish its own metadata or take
  // the media keys; Encore sets both from native.
  const ms = navigator.mediaSession;
  let realSetAction = null, metaSetter = null;
  if (ms) {
    realSetAction = MediaSession.prototype.setActionHandler.bind(ms);
    const d = Object.getOwnPropertyDescriptor(MediaSession.prototype, 'metadata');
    metaSetter = d && d.set ? d.set.bind(ms) : null;
    ms.setActionHandler = () => {};
    Object.defineProperty(ms, 'metadata', { configurable: true, get() { return null; }, set() {} });
    // No seekforward/seekbackward: Control Center then shows skip buttons.
    for (const a of ['play', 'pause', 'previoustrack', 'nexttrack', 'seekto', 'stop']) {
      try { realSetAction(a, (details) => post({ type: 'remote', action: a, time: details && details.seekTime })); } catch (e) {}
    }
  }

  // ---- "Are you still there?" never interrupts.
  setInterval(() => { window._lact = Date.now(); }, 30000);

  const player = () => document.getElementById('movie_player');
  // A page Encore replaced carries its track in the URL (`encore=1`).
  const params = new URLSearchParams(location.search);
  let expected = params.get('encore') === '1' ? params.get('v') : null;
  let video = null;
  // Encore's volume is the only volume: YouTube re-applies its own saved
  // level on every track change, so it is enforced on each media event.
  let wantVolume = null;
  // Silent mode: a page started with __encoreForceMute never makes a sound.
  const forceMute = !!window.__encoreForceMute;
  if (forceMute) {
    // Muted before any element can start, not only once it is hooked.
    const realPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function () { if (forceMute) this.muted = true; return realPlay.apply(this, arguments); };
  }
  const enforceVolume = () => {
    if (!video) return;
    if (forceMute && !video.muted) video.muted = true;
    if (wantVolume !== null && Math.abs(video.volume - wantVolume) > 0.01) video.volume = wantVolume;
    if (!forceMute && wantVolume !== null && wantVolume > 0 && video.muted) video.muted = false;
  };
  let lastTimePost = 0;
  let mismatch = 0;

  const isAd = () => {
    const p = player();
    return !!(p && p.classList && p.classList.contains('ad-showing'));
  };
  const currentId = () => {
    const p = player();
    try { return p && p.getVideoData ? p.getVideoData().video_id : null; } catch (e) { return null; }
  };

  const report = (type) => {
    if (!video) return;
    post({
      type,
      time: video.currentTime || 0,
      duration: isFinite(video.duration) ? video.duration : 0,
      paused: video.paused,
      buffering: video.readyState < 3 && !video.paused,
      ad: isAd(),
      videoId: currentId(),
    });
  };

  const hook = (v) => {
    if (!v || v === video) return;
    video = v;
    enforceVolume();
    for (const e of ['volumechange', 'play', 'playing', 'loadedmetadata', 'loadstart', 'canplay']) v.addEventListener(e, enforceVolume);
    const evs = ['play', 'playing', 'pause', 'waiting', 'durationchange', 'loadedmetadata', 'seeked', 'ratechange'];
    for (const e of evs) v.addEventListener(e, () => report('state'));
    // YouTube Music resumes its last session on load; nothing plays until Encore asks.
    v.addEventListener('play', () => { if (!expected && !isAd()) v.pause(); });
    v.addEventListener('timeupdate', () => {
      const now = Date.now();
      if (now - lastTimePost > 400) { lastTimePost = now; report('time'); }
      guard();
    });
    v.addEventListener('ended', () => {
      if (isAd()) return;
      // Nothing more is wanted until Encore asks; YouTube's own autoplay gets paused.
      const id = currentId();
      expected = null;
      post({ type: 'ended', videoId: id });
    });
    v.addEventListener('error', () => post({ type: 'error', message: String(v.error && v.error.message || 'media error') }));
    report('state');
  };

  // YouTube Music's own autoplay may start its next track; Encore's queue wins.
  const guard = () => {
    if (!expected || isAd()) { mismatch = 0; return; }
    const id = currentId();
    if (id && id !== expected) {
      mismatch += 1;
      if (mismatch === 3) {
        const p = player();
        if (p && p.loadVideoById) p.loadVideoById({ videoId: expected });
        post({ type: 'log', message: 'guard reloaded ' + expected + ' over ' + id });
      }
    } else mismatch = 0;
  };

  setInterval(() => hook(document.querySelector('video')), 500);

  const toHex = (buf) => Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
  const cookie = (name) => {
    const m = document.cookie.match(new RegExp('(?:^|; )' + name.replace(/[$()*+.?[\\\]^{|}]/g, '\\$&') + '=([^;]*)'));
    return m ? decodeURIComponent(m[1]) : null;
  };
  const sapisidHash = async () => {
    const origin = 'https://music.youtube.com';
    const ts = Math.floor(Date.now() / 1000);
    const parts = [];
    const pairs = [['SAPISIDHASH', cookie('SAPISID') || cookie('__Secure-3PAPISID')],
                   ['SAPISID1PHASH', cookie('__Secure-1PAPISID')],
                   ['SAPISID3PHASH', cookie('__Secure-3PAPISID')]];
    for (const [label, value] of pairs) {
      if (!value) continue;
      const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(ts + ' ' + value + ' ' + origin));
      parts.push(label + ' ' + ts + '_' + toHex(digest));
    }
    return parts.length ? parts.join(' ') : null;
  };

  const cfg = (k) => (window.ytcfg && window.ytcfg.get ? window.ytcfg.get(k) : undefined);

  window.__encore = {
    ready() {
      return !!(cfg('INNERTUBE_API_KEY') && cfg('INNERTUBE_CONTEXT'));
    },
    loggedIn() { return !!cfg('LOGGED_IN'); },

    async api(endpoint, body, query) {
      const ctx = JSON.parse(JSON.stringify(cfg('INNERTUBE_CONTEXT')));
      const headers = {
        'Content-Type': 'application/json',
        'X-Goog-AuthUser': String(cfg('SESSION_INDEX') || '0'),
        'X-Origin': 'https://music.youtube.com',
        'X-Youtube-Client-Name': String(cfg('INNERTUBE_CONTEXT_CLIENT_NAME') || '67'),
        'X-Youtube-Client-Version': String(cfg('INNERTUBE_CLIENT_VERSION') || ''),
      };
      const vd = cfg('VISITOR_DATA'); if (vd) headers['X-Goog-Visitor-Id'] = vd;
      const auth = await sapisidHash(); if (auth) headers['Authorization'] = auth;
      const res = await fetch('/youtubei/v1/' + endpoint + '?prettyPrint=false' + (query || ''), {
        method: 'POST', credentials: 'include', headers,
        body: JSON.stringify(Object.assign({ context: ctx }, body || {})),
      });
      return { status: res.status, text: await res.text() };
    },

    // Track change through YouTube Music's own router, so its player,
    // tokens and state stay coherent. Falls back to a page replace.
    load(id, start) {
      expected = id; mismatch = 0;
      // Same video again (repeat-one, a one-track repeat-all): the router ignores it.
      if (currentId() === id && video) {
        const p = player();
        if (p && p.seekTo) p.seekTo(start || 0, true); else video.currentTime = start || 0;
        if (p && p.playVideo) p.playVideo(); else video.play();
        return 'same';
      }
      const app = document.querySelector('ytmusic-app');
      const endpoint = { watchEndpoint: { videoId: id } };
      if (start > 0) endpoint.watchEndpoint.startTimeSeconds = Math.floor(start);
      let routed = false;
      try { if (app && app.resolveCommand) { app.resolveCommand(endpoint); routed = true; } } catch (e) {}
      if (!routed) {
        location.replace('/watch?v=' + encodeURIComponent(id) + '&encore=1' + (start > 0 ? '&t=' + Math.floor(start) + 's' : ''));
        return 'replace';
      }
      // If the router silently ignored it, replace the page.
      setTimeout(() => { if (expected === id && currentId() !== id && !isAd()) {
        post({ type: 'log', message: 'router did not start ' + id + ', replacing page' });
        location.replace('/watch?v=' + encodeURIComponent(id) + '&encore=1');
      } }, 15000);
      return 'router';
    },
    expect(id) { expected = id; mismatch = 0; },
    play() { const p = player(); if (p && p.playVideo) p.playVideo(); else if (video) video.play(); },
    pause() { const p = player(); if (p && p.pauseVideo) p.pauseVideo(); else if (video) video.pause(); },
    seek(t) { const p = player(); if (p && p.seekTo) p.seekTo(t, true); else if (video) video.currentTime = t; },
    volume(v) {
      wantVolume = v;
      const p = player();
      if (p && p.setVolume) { p.setVolume(Math.round(v * 100)); if (!forceMute && p.unMute) p.unMute(); }
      enforceVolume();
    },
    skipAd() {
      const b = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
      if (b) { b.click(); return true; }
      return false;
    },
    setMeta(m) {
      if (!metaSetter || !window.MediaMetadata) return;
      try {
        metaSetter(new MediaMetadata({ title: m.title, artist: m.artist, album: m.album || '',
          artwork: m.art ? [{ src: m.art, sizes: '544x544', type: 'image/jpeg' }] : [] }));
      } catch (e) {}
    },
    state() {
      return { hasPlayer: !!(player() && player().loadVideoById), video: !!video, id: currentId(), expected,
               time: video ? video.currentTime : 0, paused: video ? video.paused : true, ad: isAd(),
               ready: this.ready(), loggedIn: this.loggedIn(), url: location.href };
    },
  };
  const readyPoll = setInterval(() => {
    if (window.__encore.ready()) { clearInterval(readyPoll); post({ type: 'ready', loggedIn: window.__encore.loggedIn() }); }
  }, 200);
})();
