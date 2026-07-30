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
    // (.m3u8/.mpd) we saw the tab fetch; if there is none (e.g. YouTube, which
    // streams via range requests), fall back to the PAGE URL so yt-dlp's
    // site-specific extractor handles it — same path the popup's PAGE item uses.
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
  if (request.action === 'reveal') {
    try {
      const port = chrome.runtime.connectNative(HOST);
      port.onMessage.addListener(() => { try { port.disconnect(); } catch (e) {} });
      port.onDisconnect.addListener(() => {});
      port.postMessage({ cmd: 'reveal', path: request.path });
    } catch (e) {}
    sendResponse({ ok: true });
    return;
  }
});

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
}

chrome.webRequest.onBeforeRequest.addListener((d) => {
  if (d.tabId < 0) return;
  if (d.type === 'main_frame') { chrome.storage.session.remove(mediaKey(d.tabId)); return; }
  if (MANIFEST_RE.test(d.url)) recordMedia(d.tabId, d.url);
}, { urls: ['<all_urls>'] });

chrome.tabs.onRemoved.addListener((id) => { chrome.storage.session.remove(mediaKey(id)); });

// ---- Download queue -------------------------------------------------------
function processQueue() {
  if (busy) return;
  const job = queue.shift();
  if (!job) return;
  busy = true;
  startDownload(job.url, job.referer, job.tabId, () => { busy = false; processQueue(); });
}

async function startDownload(url, referer, tabId, onDone) {
  const { savePath } = await chrome.storage.sync.get('savePath');
  const S = (o) => setDL(url, o, tabId);

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

  port.onMessage.addListener((msg) => {
    if (!msg || !msg.type) return;
    if (msg.type === 'progress') {
      if (msg.line) console.log('[vid-dl][host]', msg.line);
      S({ state: 'downloading', percent: msg.percent });
      if (typeof msg.percent === 'number') flashBadge(Math.round(msg.percent) + '%', '#1565c0', false);
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
    port.postMessage({ url, savePath: savePath || '', referer: referer || '', format: 'best' });
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
