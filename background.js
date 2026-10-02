// Video Downloader — thin client for a local yt-dlp native messaging host.
// The extension only forwards a URL; host.ps1 runs yt-dlp (+ ffmpeg) and saves.
//
// Single source of truth for download state lives HERE, keyed by the download
// target URL (not by any per-UI id). Both the popup list and the on-page badge
// are just views: they identify a download by its URL, so a download started in
// one shows up in the other automatically. State is mirrored to session storage
// so it survives the popup closing and the service worker sleeping.

const HOST = 'com.sbk.ytdlp';

// Downloads run ONE AT A TIME. Spawning several native-host processes at once
// makes them collide on the shared yt-dlp.exe (self-update) / log file and the
// connection dies. So requests just enqueue; we drain the queue serially.
const queue = [];
let busy = false;

// url -> { state:'queued'|'starting'|'downloading'|'done'|'error', percent, file, path, message, hostMissing }
const downloads = {};
chrome.storage.session.get('downloads').then((g) => { Object.assign(downloads, g.downloads || {}); });

const ACTIVE = { queued: 1, starting: 1, downloading: 1 };

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === 'download') {
    const url = request.url || (sender.tab && sender.tab.url);
    const referer = request.referer || (sender.tab && sender.tab.url) || '';
    const tabId = request.tabId != null ? request.tabId : (sender.tab && sender.tab.id);
    if (url) enqueue(url, referer, tabId);
    sendResponse({ url: url || null });
    return;
  }
  if (request.action === 'downloadStream') {
    // A blob:/MSE video has no downloadable DOM src. Prefer the manifest
    // (.m3u8/.mpd) we saw the tab fetch; if there is none (some players stream via
    // plain range requests), fall back to the PAGE URL so yt-dlp's site-specific
    // extractor handles it — same path the popup's PAGE item uses.
    const tabId = request.tabId != null ? request.tabId : (sender.tab && sender.tab.id);
    const pageUrl = (sender.tab && sender.tab.url) || request.referer || '';
    const referer = request.referer || pageUrl;
    resolveStreamUrl(tabId).then((url) => {
      const target = url || pageUrl;
      if (target) enqueue(target, referer, tabId);
      else flashBadge('?', '#c62828');
      sendResponse({ url: target || null });
    });
    return true;
  }
  if (request.action === 'resolveStream') {
    // Content script asks which URL a blob/MSE video maps to (so its badge keys
    // off the same URL the download will use): manifest if sniffed, else the page.
    const tabId = sender.tab && sender.tab.id;
    const pageUrl = (sender.tab && sender.tab.url) || '';
    resolveStreamUrl(tabId).then((url) => sendResponse({ url: (url || pageUrl) || null }));
    return true;
  }
  if (request.action === 'getDownloads') {
    chrome.storage.session.get('downloads').then((g) => sendResponse(g.downloads || {}));
    return true;
  }
  if (request.action === 'verifyDownloads') {
    // Ask the host which finished files still exist on disk; drop the ones the
    // user has deleted so their control goes back to "download".
    verifyDownloads().then((map) => sendResponse(map));
    return true;
  }
  if (request.action === 'getMedia') {
    const key = mediaKey(request.tabId);
    chrome.storage.session.get(key).then((g) => sendResponse(g[key] || []));
    return true;
  }
  if (request.action === 'checkHost') {
    hostReachable().then((ok) => sendResponse({ ok }));
    return true;
  }
  if (request.action === 'reveal') {
    // Reveal ONLY a file this extension recorded as downloaded. The path arrives
    // from a content script and the native host feeds it to explorer.exe, which
    // launches whatever executable path it is handed - so an unchecked value here
    // would be a way for a page to run a local program. Session storage is the
    // source of truth: the in-memory map may still be empty right after the
    // service worker wakes.
    chrome.storage.session.get('downloads').then((g) => {
      const map = Object.assign({}, g.downloads || {}, downloads);
      const ok = !!request.path && Object.keys(map).some((u) => map[u] && map[u].path === request.path);
      if (ok) revealPath(request.path);
      else console.warn('[vid-dl] reveal refused for an unrecorded path');
      sendResponse({ ok });
    }).catch(() => sendResponse({ ok: false })); // never leave the port hanging
    return true;
  }
});

// Hand a verified path to the host, which opens Explorer on it.
function revealPath(path) {
  try {
    const port = chrome.runtime.connectNative(HOST);
    port.onMessage.addListener(() => { try { port.disconnect(); } catch (e) {} });
    port.onDisconnect.addListener(() => {});
    port.postMessage({ cmd: 'reveal', path });
  } catch (e) {}
}

// ---- Shared download state ----------------------------------------------
function setDL(url, patch, tabId) {
  downloads[url] = Object.assign({ url }, downloads[url], patch);
  chrome.storage.session.set({ downloads });
  const status = Object.assign({}, downloads[url]);
  // runtime.sendMessage reaches extension pages (the popup); content scripts
  // (the on-page badge) only get messages sent to their tab. Send to both.
  chrome.runtime.sendMessage({ action: 'status', status }).catch(() => {});
  if (tabId != null) chrome.tabs.sendMessage(tabId, { action: 'status', status }).catch(() => {});
}

function enqueue(url, referer, tabId) {
  const cur = downloads[url];
  if (cur && ACTIVE[cur.state]) { setDL(url, {}, tabId); return; } // already going; just refresh the requester
  setDL(url, { state: 'queued', percent: 0, file: null, path: null, message: null, hostMissing: false }, tabId);
  queue.push({ url, referer, tabId });
  processQueue();
}

function resolveStreamUrl(tabId) {
  return chrome.storage.session.get(mediaKey(tabId)).then((g) => {
    const arr = g[mediaKey(tabId)] || [];
    return arr.length ? arr[arr.length - 1].url : null;
  });
}

// Cheap liveness probe for the popup's banner: connect and ask the host to check
// an empty path list. A reply means it is registered AND runnable; a throw or a
// disconnect means the user still has to run native/install.ps1 once.
// Skipped while a download holds the host — spawning a second host process would
// collide with it (see the queue note above), and a running download is already
// proof the host is fine.
function hostReachable() {
  if (busy) return Promise.resolve(true);
  return new Promise((resolve) => {
    let done = false;
    let port;
    const finish = (ok) => {
      if (done) return; done = true;
      try { port.disconnect(); } catch (e) {}
      resolve(ok);
    };
    try { port = chrome.runtime.connectNative(HOST); } catch (e) { resolve(false); return; }
    port.onMessage.addListener(() => finish(true));
    port.onDisconnect.addListener(() => finish(false));
    try { port.postMessage({ cmd: 'exists', paths: [] }); } catch (e) { finish(false); }
    setTimeout(() => finish(false), 5000);
  });
}

// Ask the native host which of the given file paths are gone. Returns the list
// of missing paths; on any failure (host missing, timeout) returns [] so we
// never prune on uncertainty.
function hostExists(paths) {
  return new Promise((resolve) => {
    let done = false;
    let port;
    const finish = (missing) => {
      if (done) return; done = true;
      try { port.disconnect(); } catch (e) {}
      resolve(missing);
    };
    try { port = chrome.runtime.connectNative(HOST); } catch (e) { resolve([]); return; }
    port.onMessage.addListener((msg) => {
      if (msg && msg.type === 'exists') {
        finish(Array.isArray(msg.missing) ? msg.missing : (msg.missing ? [msg.missing] : []));
      }
    });
    port.onDisconnect.addListener(() => finish([]));
    try { port.postMessage({ cmd: 'exists', paths }); } catch (e) { finish([]); }
    setTimeout(() => finish([]), 6000);
  });
}

async function verifyDownloads() {
  const urlByPath = {};
  const paths = [];
  Object.keys(downloads).forEach((url) => {
    const d = downloads[url];
    if (d && d.state === 'done' && d.path) { paths.push(d.path); urlByPath[d.path] = url; }
  });
  if (!paths.length) return downloads;
  const missing = await hostExists(paths);
  let changed = false;
  missing.forEach((p) => {
    const url = urlByPath[p];
    if (url && downloads[url]) { delete downloads[url]; changed = true; } // gone -> back to "download"
  });
  if (changed) await chrome.storage.session.set({ downloads });
  return downloads;
}

// ---- Cookies -------------------------------------------------------------
// Cookies for ONE site, not the whole jar. yt-dlp's --cookies-from-browser hands
// it every cookie Chrome holds, and on Chrome 127+ it usually cannot read any of
// them anyway: the cookie DB is locked while Chrome runs and the values are under
// app-bound encryption. Asking the browser for just the cookies that would be sent
// to this download is both far narrower and the only version that actually works.
//
// getAll({url}) is the right primitive - it returns exactly what a request to that
// URL would carry, parent-domain cookies included. Do NOT try to derive a
// registrable domain by hand: getAll({domain:'co.uk'}) would sweep up every
// cookie under that suffix.
async function collectCookies(url, referer) {
  const urls = [url, referer].filter((u) => u && /^https?:/i.test(u));
  const seen = new Set();
  const out = [];
  for (const u of urls) {
    let list;
    try { list = await chrome.cookies.getAll({ url: u }); } catch (e) { continue; }
    (list || []).forEach((c) => {
      const key = c.domain + '\t' + c.path + '\t' + c.name;
      if (seen.has(key)) return;
      seen.add(key);
      out.push(c);
    });
  }
  return out.length ? toNetscape(out) : '';
}

// Netscape cookies.txt - the only shape yt-dlp's --cookies accepts. The magic
// first line is mandatory (Python's MozillaCookieJar rejects a file without it),
// the seven fields are TAB separated (spaces are the classic cause of "does not
// look like a Netscape format cookies file"), and yt-dlp strips the #HttpOnly_
// prefix itself. Chrome already reports domain cookies with a leading dot, so
// c.domain goes through verbatim; hostOnly is the inverse of "include subdomains".
function toNetscape(cookies) {
  const lines = ['# Netscape HTTP Cookie File'];
  cookies.forEach((c) => {
    lines.push((c.httpOnly ? '#HttpOnly_' : '') + [
      c.domain,
      c.hostOnly ? 'FALSE' : 'TRUE',
      c.path || '/',
      c.secure ? 'TRUE' : 'FALSE',
      c.session ? 0 : Math.floor(c.expirationDate || 0),
      c.name,
      c.value
    ].join('\t'));
  });
  return lines.join('\n') + '\n';
}

// ---- Media (HLS/DASH manifest) sniffing ---------------------------------
// MSE/blob videos have no downloadable DOM src; their real source is a manifest
// (.m3u8/.mpd) the page fetches. We observe network requests and remember those
// per tab (in session storage) so the popup / badge can offer the actual stream.
const MANIFEST_RE = /\.(m3u8|mpd)(\?|#|$)/i;

function mediaKey(tabId) { return 'media_' + tabId; }

async function recordMedia(tabId, url) {
  const key = mediaKey(tabId);
  const g = await chrome.storage.session.get(key);
  const arr = g[key] || [];
  if (arr.some((h) => h.url === url)) return;
  arr.push({ url });
  while (arr.length > 20) arr.shift();
  await chrome.storage.session.set({ [key]: arr });
  // Tell the tab a stream URL just appeared, so a blob/MSE badge that resolved to
  // a page-URL fallback (before this manifest was sniffed) can re-key to it and
  // pick up a matching finished download.
  chrome.tabs.sendMessage(tabId, { action: 'mediaFound', url }).catch(() => {});
}

chrome.webRequest.onBeforeRequest.addListener((d) => {
  if (d.tabId < 0) return;
  if (d.type === 'main_frame') { chrome.storage.session.remove(mediaKey(d.tabId)); return; }
  if (MANIFEST_RE.test(d.url)) recordMedia(d.tabId, d.url);
}, { urls: ['<all_urls>'] });

chrome.tabs.onRemoved.addListener((id) => { chrome.storage.session.remove(mediaKey(id)); });

// A tab's URL changed. Covers same-document (SPA) navigation too, which never
// issues a main_frame request: the previously sniffed manifests belong to the
// video the user just left, so drop them, then tell the tab so its on-page
// badges stop pointing at the old download target.
chrome.tabs.onUpdated.addListener((tabId, info) => {
  if (!info.url) return;
  chrome.storage.session.remove(mediaKey(tabId)).then(() => {
    chrome.tabs.sendMessage(tabId, { action: 'navigated', url: info.url }).catch(() => {});
  });
});

// ---- Download queue -------------------------------------------------------
function processQueue() {
  if (busy) return;
  const job = queue.shift();
  if (!job) return;
  busy = true;
  startDownload(job.url, job.referer, job.tabId, () => { busy = false; processQueue(); });
}

async function startDownload(url, referer, tabId, onDone) {
  const { savePath, useCookies, quality } = await chrome.storage.sync.get(['savePath', 'useCookies', 'quality']);
  const S = (o) => setDL(url, o, tabId);

  // Gathered here rather than in the host: only the extension can read the cookie
  // store, and only for the one URL being downloaded.
  let cookiesText = '';
  if (useCookies) {
    cookiesText = await collectCookies(url, referer);
    if (!cookiesText) console.warn('[vid-dl] no cookies stored for this site; downloading without them');
  }

  let released = false;
  const release = () => { if (!released) { released = true; if (onDone) onDone(); } };

  S({ state: 'starting' });

  let port;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    S({ state: 'error', message: String(e) });
    flashBadge('ERR', '#c62828');
    release();
    return;
  }

  let finished = false;
  let lastPercent = -1;

  port.onMessage.addListener((msg) => {
    if (!msg || !msg.type) return;
    if (msg.type === 'progress') {
      if (msg.line) console.log('[vid-dl][host]', msg.line);
      // Most host lines are plain log output with no percent in them. Writing
      // that absence into the state blanked the number in the popup / badge on
      // every such line, so only a real, non-decreasing percent updates it.
      const patch = { state: 'downloading' };
      if (typeof msg.percent === 'number' && msg.percent >= lastPercent) {
        lastPercent = msg.percent;
        patch.percent = msg.percent;
      }
      S(patch);
      if (patch.percent != null) flashBadge(Math.round(patch.percent) + '%', '#1565c0', false);
    } else if (msg.type === 'done') {
      finished = true;
      console.log('[vid-dl][host] done', msg.file);
      S({ state: 'done', percent: 100, file: msg.file, path: msg.path });
      flashBadge('OK', '#2e7d32');
      try { port.disconnect(); } catch (e) {}
      release();
    } else if (msg.type === 'error') {
      finished = true;
      console.warn('[vid-dl][host] error', msg.message);
      S({ state: 'error', message: msg.message });
      flashBadge('ERR', '#c62828');
      try { port.disconnect(); } catch (e) {}
      release();
    }
  });

  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    console.log('[vid-dl] port disconnected; lastError=', err ? err.message : '(none)', '| finished=', finished);
    if (!finished) {
      S({ state: 'error', message: err ? err.message : 'host disconnected', hostMissing: !!err });
      flashBadge('ERR', '#c62828');
    }
    release();
  });

  try {
    port.postMessage({ url, savePath: savePath || '', referer: referer || '', cookiesText, format: 'best', quality: quality || '4320' });
  } catch (e) {
    S({ state: 'error', message: String(e) });
    flashBadge('ERR', '#c62828');
    release();
  }
}

let badgeTimer = null;
function flashBadge(text, color, autoClear = true) {
  try {
    chrome.action.setBadgeBackgroundColor({ color });
    chrome.action.setBadgeText({ text });
    if (badgeTimer) { clearTimeout(badgeTimer); badgeTimer = null; }
    if (autoClear) badgeTimer = setTimeout(() => chrome.action.setBadgeText({ text: '' }), 3000);
  } catch (e) {}
}
