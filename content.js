// Modifier+Click on a video hands a URL to the local yt-dlp host (via background).
// Direct http(s) media -> that URL; blob:/MSE -> the page URL (yt-dlp extracts).
// The modifier combo is configurable in the popup (default Ctrl+Alt).
let clickMod = 'ctrl+alt';
let clickButton = 'left';
let shortcutEnabled = true;
let badgeEnabled = true; // show the on-video hover button
chrome.storage.sync.get(['clickMod', 'clickButton', 'shortcutEnabled', 'badgeEnabled'], ({ clickMod: cm, clickButton: cb, shortcutEnabled: se, badgeEnabled: be }) => {
  if (cm) clickMod = cm;
  if (cb) clickButton = cb;
  if (se !== undefined) shortcutEnabled = se !== false;
  if (be !== undefined) badgeEnabled = be !== false;
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'sync') return;
  if (changes.clickMod) clickMod = changes.clickMod.newValue || 'ctrl+alt';
  if (changes.clickButton) clickButton = changes.clickButton.newValue || 'left';
  if (changes.shortcutEnabled) shortcutEnabled = changes.shortcutEnabled.newValue !== false;
  if (changes.badgeEnabled) { badgeEnabled = changes.badgeEnabled.newValue !== false; scheduleBadges(); }
});

function modMatches(e) {
  const need = { ctrl: false, alt: false, shift: false, meta: false };
  clickMod.split('+').forEach((k) => { if (k in need) need[k] = true; });
  if (!(need.ctrl || need.alt || need.shift || need.meta)) return false; // never fire on a plain click
  return e.ctrlKey === need.ctrl && e.altKey === need.alt && e.shiftKey === need.shift && e.metaKey === need.meta;
}

function handleShortcut(event) {
  if (!shortcutEnabled) return;
  if (!modMatches(event)) return;
  const video = findVideo(event);
  if (!video) return;
  event.preventDefault();
  event.stopPropagation();
  triggerDownload(video);
}

// Left-click shortcut fires on 'click'; right-click on 'contextmenu' (which also
// lets us suppress the browser menu when the combo matches).
document.addEventListener('click', function (event) {
  if (clickButton !== 'left') return;
  handleShortcut(event);
}, true);
document.addEventListener('contextmenu', function (event) {
  if (clickButton !== 'right') return;
  handleShortcut(event);
}, true);

// Start a download for one <video>. Plain http(s) media -> that URL; blob:/MSE ->
// ask the background for the stream manifest it saw this tab fetch (.m3u8/.mpd).
// The background tracks state by URL, so the matching badge updates automatically.
function triggerDownload(video) {
  const src = videoSrc(video);
  const base = { referer: location.href, title: document.title };
  try {
    if (src && /^https?:/i.test(src)) {
      chrome.runtime.sendMessage(Object.assign({ action: 'download', url: src }, base));
    } else {
      chrome.runtime.sendMessage(Object.assign({ action: 'downloadStream' }, base));
    }
  } catch (e) {}
}

chrome.runtime.onMessage.addListener((req, sender, sendResponse) => {
  // The popup asks for the list of videos currently on this page.
  if (req && req.action === 'listVideos') {
    const r = collectVideos();
    sendResponse({ pageUrl: location.href, title: document.title, videos: r.videos, streamThumb: r.streamThumb });
    return;
  }
  // Background progress broadcast -> update the matching on-page badge.
  if (req && req.action === 'status') { applyBadgeStatus(req.status); }
  // A stream manifest was (re)sniffed for this tab -> re-key blob/MSE badges to it
  // and re-hydrate (fixes the reload race where the badge resolved before the
  // page had re-fetched its manifest).
  if (req && req.action === 'mediaFound' && req.url) {
    vdlBadges.forEach((b, video) => {
      const src = videoSrc(video);
      if (src && /^https?:/i.test(src)) return; // direct video, unaffected
      b.dataset.dlurl = req.url;
      hydrateBadge(b);
    });
  }
});

// Best-effort thumbnail for a <video>: a small JPEG of the current frame, or the
// poster. Cross-origin frames taint the canvas (SecurityError) -> we fall back to
// the poster, or return '' (the popup shows a placeholder).
function captureThumb(v) {
  try {
    if (v.readyState >= 2 && v.videoWidth > 0) {
      const w = 120;
      const h = Math.max(1, Math.round(w * v.videoHeight / v.videoWidth));
      const c = document.createElement('canvas');
      c.width = w; c.height = h;
      c.getContext('2d').drawImage(v, 0, 0, w, h);
      return c.toDataURL('image/jpeg', 0.6);
    }
  } catch (e) { /* tainted / not drawable */ }
  try { if (v.poster) return v.poster; } catch (e) {}
  return '';
}

// Only real, downloadable http(s) <video> sources. blob:/MSE videos have no
// usable DOM src — those are surfaced by the background's manifest sniffing and
// merged in by the popup, so each list entry is a distinct, real video.
function collectVideos() {
  const out = [];
  const seen = new Set();
  let streamThumb = ''; // representative frame for blob/MSE (manifest) videos
  document.querySelectorAll('video').forEach((v) => {
    const src = videoSrc(v);
    const thumb = captureThumb(v);
    if (!/^https?:/i.test(src)) { if (!streamThumb && thumb) streamThumb = thumb; return; }
    if (seen.has(src)) return;
    seen.add(src);
    let label;
    try { label = decodeURIComponent(new URL(src).pathname.split('/').pop() || src); } catch (e) { label = src; }
    const dim = (v.videoWidth && v.videoHeight) ? (v.videoWidth + 'x' + v.videoHeight) : '';
    out.push({ url: src, kind: 'direct', label: label, dim: dim, thumb: thumb });
  });
  return { videos: out, streamThumb: streamThumb };
}

function findVideo(event) {
  if (event.target && event.target.tagName === 'VIDEO') return event.target;
  if (event.target && event.target.closest) {
    const c = event.target.closest('video');
    if (c) return c;
  }
  const stack = document.elementsFromPoint(event.clientX, event.clientY);
  for (const el of stack) { if (el.tagName === 'VIDEO') return el; }
  return null;
}

function videoSrc(video) {
  let s = video.currentSrc || video.src;
  if (!s) {
    const source = video.querySelector && video.querySelector('source[src]');
    if (source) s = source.src;
  }
  return s || '';
}

// ---- On-page download badge (shown on hover, just right of each video) ----
// On mouse hover a small badge appears just outside a <video>'s top-right corner.
// It's appended at the document root with a max z-index, so it stays clickable
// even when the page covers the video with an anti-download overlay. The badge is
// stateful and mirrors the popup button: download (red) -> % (blue) -> open folder
// (green), driven by the background's status broadcasts, matched here by URL.
const DL_ICON =
  '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#fff" ' +
  'stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">' +
  '<path d="M12 3v12"/><path d="M7 11l5 5 5-5"/><path d="M5 21h14"/></svg>';
const FOLDER_ICON =
  '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#fff" ' +
  'stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">' +
  '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h6a2 2 0 0 1 2 2v1H3z"/><path d="M3 10h18l-1.5 8a2 2 0 0 1-2 1.5H6.5a2 2 0 0 1-2-1.5z"/></svg>';

const BG = {
  idle: 'rgba(229,57,53,.92)',      // red
  downloading: 'rgba(21,101,192,.95)', // blue
  done: 'rgba(46,125,50,.95)',      // green
  error: 'rgba(198,40,40,.95)'      // dark red
};

const vdlBadges = new Map(); // video element -> badge element
let vdlScheduled = false;
let ptrX = -1, ptrY = -1;    // last cursor position, for geometry-based hover
let dlCache = {};            // url -> last known status (shared with popup, keyed by URL)

// Snapshot what the background knows (cheap cached state, no host call), so badges
// reflect downloads started earlier / from the popup even across a page reload.
// Re-applied to existing badges to avoid a create-vs-fetch race (badges made
// before this resolves would otherwise stay on "download"). Disk verification is
// only done from the popup's refresh button.
function refreshDlCache() {
  chrome.runtime.sendMessage({ action: 'getDownloads' }, (m) => {
    void chrome.runtime.lastError;
    dlCache = m || {};
    vdlBadges.forEach(hydrateBadge);
    scheduleBadges();
  });
}
refreshDlCache();

// Set a badge from the shared state, or reset a now-stale "done" badge (its file
// was deleted, so it's no longer in the map) back to "download".
function hydrateBadge(b) {
  const u = b.dataset.dlurl;
  if (u && dlCache[u]) { applyStatusToBadge(b, dlCache[u]); return; }
  if (b.dataset.state === 'done') { b.dataset.state = 'idle'; b.dataset.path = ''; renderBadge(b); }
}

// Paint a badge to match its state: download icon / percent / open-folder icon.
function renderBadge(b) {
  const s = b.dataset.state || 'idle';
  b.style.background = BG[s] || BG.idle;
  if (s === 'downloading') {
    const p = b.dataset.percent;
    b.innerHTML = '<span style="color:#fff;font:700 9px/1 -apple-system,Segoe UI,sans-serif">' +
      (p !== '' && p != null ? p + '%' : '...') + '</span>';
    b.title = 'Downloading';
  } else if (s === 'done') {
    b.innerHTML = FOLDER_ICON; b.title = 'Open folder';
  } else {
    b.innerHTML = DL_ICON; b.title = (s === 'error') ? 'Failed - click to retry' : 'Download this video';
  }
}

function stateFromStatus(st) {
  if (st.state === 'queued' || st.state === 'starting' || st.state === 'downloading') return 'downloading';
  if (st.state === 'done' || st.state === 'error') return st.state;
  return 'idle';
}

// Push a background status object onto a badge's visible state.
function applyStatusToBadge(b, st) {
  b.dataset.state = stateFromStatus(st);
  if (b.dataset.state === 'downloading') b.dataset.percent = (typeof st.percent === 'number') ? String(Math.round(st.percent)) : '';
  if (b.dataset.state === 'done') b.dataset.path = st.path || '';
  renderBadge(b);
}

// The download URL a badge maps to: the http(s) src directly, or (blob/MSE) the
// stream manifest the background sniffed for this tab.
function resolveBadgeUrl(video, cb) {
  const src = videoSrc(video);
  if (src && /^https?:/i.test(src)) { cb(src); return; }
  chrome.runtime.sendMessage({ action: 'resolveStream' }, (r) => { void chrome.runtime.lastError; cb(r && r.url); });
}

function initBadge(b, video) {
  resolveBadgeUrl(video, (url) => {
    if (!url) return;
    b.dataset.dlurl = url;
    hydrateBadge(b);
  });
}

function startBadge(b, video) {
  b.dataset.state = 'downloading';
  b.dataset.percent = '';
  renderBadge(b);
  scheduleBadges(); // keep it pinned even if the cursor leaves
  const src = videoSrc(video);
  if (src && /^https?:/i.test(src)) {
    b.dataset.dlurl = src;
    chrome.runtime.sendMessage({ action: 'download', url: src, referer: location.href, title: document.title });
  } else {
    chrome.runtime.sendMessage({ action: 'downloadStream', referer: location.href, title: document.title }, (r) => {
      void chrome.runtime.lastError;
      if (r && r.url) b.dataset.dlurl = r.url;
      else { b.dataset.state = 'error'; renderBadge(b); }
    });
  }
}

function makeBadge(video) {
  const b = document.createElement('div');
  b.setAttribute('aria-label', 'Download video');
  b.dataset.mediadl = 'video'; // lets the Image Downloader detect/avoid our badge
  b.dataset.state = 'idle';
  b.style.cssText = [
    'position:fixed', 'z-index:2147483647', 'width:30px', 'height:30px',
    'box-sizing:border-box', 'display:none', 'align-items:center', 'justify-content:center',
    'border-radius:50%', 'box-shadow:0 1px 5px rgba(0,0,0,.45)',
    'cursor:pointer', 'transition:transform .1s, background .1s', 'padding:0', 'border:0'
  ].join(';');
  renderBadge(b);
  const stop = (e) => { e.preventDefault(); e.stopPropagation(); };
  ['mousedown', 'pointerdown', 'contextmenu'].forEach((t) => b.addEventListener(t, stop, true));
  b.addEventListener('mouseenter', () => { b.style.transform = 'scale(1.12)'; });
  b.addEventListener('mouseleave', () => { b.style.transform = 'scale(1)'; });
  b.addEventListener('click', (e) => {
    stop(e);
    const s = b.dataset.state;
    if (s === 'downloading') return;
    if (s === 'done') {
      if (b.dataset.path) chrome.runtime.sendMessage({ action: 'reveal', path: b.dataset.path });
      return;
    }
    startBadge(b, video); // idle or error -> start / retry
  }, true);
  document.documentElement.appendChild(b);
  initBadge(b, video);
  return b;
}

// A background status broadcast -> update every badge pointing at that URL. Also
// cache it so badges created later start in the right state.
function applyBadgeStatus(s) {
  if (!s || !s.url) return;
  dlCache[s.url] = s;
  vdlBadges.forEach((b) => { if (b.dataset.dlurl === s.url) applyStatusToBadge(b, s); });
  scheduleBadges(); // recompute visibility (pin while downloading, release when done)
}

function positionBadges() {
  vdlScheduled = false;
  if (!badgeEnabled) { vdlBadges.forEach((b) => { b.style.display = 'none'; }); return; }
  const vids = document.querySelectorAll('video');
  const live = new Set();
  const rects = new Map();

  // Pick the video the cursor is over. A generous zone up/right of the frame
  // keeps the badge (which sits just outside the top-right) reachable, and using
  // the pointer position rather than the event target works even when the page
  // covers the video with an anti-download overlay.
  let hover = null;
  vids.forEach((v) => {
    live.add(v);
    if (!vdlBadges.has(v)) vdlBadges.set(v, makeBadge(v));
    const r = v.getBoundingClientRect();
    rects.set(v, r);
    if (r.width > 60 && r.height > 40 &&
        ptrX >= r.left && ptrX <= r.right + 44 && ptrY >= r.top - 44 && ptrY <= r.bottom) hover = v;
  });

  vids.forEach((v) => {
    const b = vdlBadges.get(v);
    const r = rects.get(v);
    const onScreen = r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
    // Normally shown only on hover, but stay visible while downloading (so the %
    // keeps showing) and once done (so "open folder" stays handy).
    const persist = b.dataset.state === 'downloading' || b.dataset.state === 'done';
    if ((v !== hover && !persist) || !onScreen) { b.style.display = 'none'; return; }
    b.style.display = 'flex';
    // Just OUTSIDE the video, to the RIGHT of its top-right corner. If there's no
    // room outside (video against the right edge), tuck it inside the corner.
    // Clamp so the badge never leaves the viewport.
    const size = 30, gap = 6;
    let top = r.top + gap;
    let left = r.right + gap;
    if (left + size > innerWidth - 2) left = r.right - size - gap;
    top = Math.max(2, Math.min(top, innerHeight - size - 2));
    left = Math.max(2, Math.min(left, innerWidth - size - 2));
    b.style.top = top + 'px';
    b.style.left = left + 'px';
  });

  vdlBadges.forEach((b, v) => { if (!live.has(v)) { b.remove(); vdlBadges.delete(v); } });
}

function scheduleBadges() {
  if (vdlScheduled) return;
  vdlScheduled = true;
  requestAnimationFrame(positionBadges);
}

addEventListener('mousemove', (e) => { ptrX = e.clientX; ptrY = e.clientY; scheduleBadges(); }, true);
addEventListener('scroll', scheduleBadges, true);
addEventListener('resize', scheduleBadges, true);
try { new MutationObserver(scheduleBadges).observe(document.documentElement, { childList: true, subtree: true }); } catch (e) {}
scheduleBadges();
