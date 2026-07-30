// Video Downloader — thin client for a local yt-dlp native messaging host.
// The extension does NOT download anything itself; it just hands the page URL to
// the local host (host.py), which runs yt-dlp (extract + decrypt + merge via
// ffmpeg) and saves the file. See native/README.md for install.

const HOST = 'com.sbk.ytdlp';

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === 'download') {
    const url = request.url || (sender.tab && sender.tab.url);
    if (url) startDownload(url);
    sendResponse({ started: !!url });
    return;
  }
  if (request.action === 'getStatus') {
    chrome.storage.session.get('status').then((g) => sendResponse(g.status || null));
    return true;
  }
});

async function startDownload(pageUrl) {
  const { savePath } = await chrome.storage.sync.get('savePath');
  console.log('[vid-dl] startDownload url=', pageUrl, '| savePath=', JSON.stringify(savePath || '(default)'));
  await setStatus({ state: 'starting', url: pageUrl });

  let port;
  try {
    port = chrome.runtime.connectNative(HOST);
    console.log('[vid-dl] connectNative ok:', HOST);
  } catch (e) {
    console.error('[vid-dl] connectNative threw', e);
    await setStatus({ state: 'error', url: pageUrl, message: String(e) });
    flashBadge('ERR', '#c62828');
    return;
  }

  let finished = false;

  port.onMessage.addListener(async (msg) => {
    if (!msg || !msg.type) return;
    if (msg.type === 'progress') { if (msg.line) console.log('[vid-dl][host]', msg.line); }
    else console.log('[vid-dl][host]', JSON.stringify(msg));
    if (msg.type === 'progress') {
      await setStatus({ state: 'downloading', url: pageUrl, percent: msg.percent, line: msg.line });
      if (typeof msg.percent === 'number') flashBadge(Math.round(msg.percent) + '%', '#1565c0', false);
    } else if (msg.type === 'done') {
      finished = true;
      await setStatus({ state: 'done', url: pageUrl, file: msg.file });
      flashBadge('OK', '#2e7d32');
      try { port.disconnect(); } catch (e) {}
    } else if (msg.type === 'error') {
      finished = true;
      await setStatus({ state: 'error', url: pageUrl, message: msg.message });
      flashBadge('ERR', '#c62828');
      try { port.disconnect(); } catch (e) {}
    }
  });

  port.onDisconnect.addListener(async () => {
    const err = chrome.runtime.lastError;
    console.log('[vid-dl] port disconnected; lastError=', err ? err.message : '(none)', '| finished=', finished);
    if (!finished) {
      const message = err ? err.message : 'host disconnected';
      // Most common: host not installed / not registered.
      await setStatus({ state: 'error', url: pageUrl, message, hostMissing: !!err });
      flashBadge('ERR', '#c62828');
    }
  });

  try {
    port.postMessage({ url: pageUrl, savePath: savePath || '', format: 'best' });
  } catch (e) {
    await setStatus({ state: 'error', url: pageUrl, message: String(e) });
    flashBadge('ERR', '#c62828');
  }
}

async function setStatus(status) {
  status.ts = 0;
  await chrome.storage.session.set({ status });
  // Best-effort broadcast to an open popup (ignored if none).
  chrome.runtime.sendMessage({ action: 'status', status }).catch(() => {});
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
