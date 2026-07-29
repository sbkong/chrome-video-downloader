const RULE_ID = 23456;

// Intended filenames for the downloads we start, in order.
const pendingPaths = [];

// Register onDeterminingFilename ONLY while we have a download in flight, and remove
// it as soon as our queue drains. onDeterminingFilename is global (it fires for every
// download in the browser), so a permanently-registered listener from each extension
// makes Chrome's multi-listener conflict resolution drop filenames. Keeping the
// listener registered only while we are actively downloading means an idle extension
// never interferes with the companion Image Downloader's downloads (or anything else).
function determineFilename(item, suggest) {
  const path = pendingPaths.shift();
  if (path) {
    suggest({ filename: path, conflictAction: 'uniquify' });
  } else {
    suggest();
  }
  if (pendingPaths.length === 0) {
    chrome.downloads.onDeterminingFilename.removeListener(determineFilename);
  }
}

function enqueue(path) {
  pendingPaths.push(path);
  if (!chrome.downloads.onDeterminingFilename.hasListener(determineFilename)) {
    chrome.downloads.onDeterminingFilename.addListener(determineFilename);
  }
}

chrome.runtime.onMessage.addListener((request, sender) => {
  if (request.action === 'downloadVideo') {
    const referer = request.referer || sender.url;
    handleDownload(request.url, referer, request.title || '');
  }
});

async function handleDownload(videoUrl, referer, title) {
  const subfolder = await getSubfolder(referer, title);

  try {
    // Referer for the fetch() below. fetch() can't set Referer itself (forbidden
    // header), so declarativeNetRequest sets it on the xmlhttprequest. This is the
    // path that reliably carries Referer — unlike a direct chrome.downloads request,
    // where the header rule doesn't take effect (that's why hotlink videos failed).
    await chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds: [RULE_ID],
      addRules: [{
        id: RULE_ID,
        priority: 1,
        action: {
          type: 'modifyHeaders',
          requestHeaders: [{
            header: 'Referer',
            operation: 'set',
            value: referer
          }]
        },
        condition: {
          urlFilter: '*',
          resourceTypes: ['xmlhttprequest', 'media', 'other', 'object', 'sub_frame']
        }
      }]
    });

    const response = await fetch(videoUrl, { headers: { 'Referer': referer } });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    const blob = await response.blob();
    const dataUrl = await blobToDataUrl(blob);
    const path = buildPath(subfolder, getFilename(videoUrl));
    enqueue(path);

    await chrome.downloads.download({
      url: dataUrl,
      filename: path,
      conflictAction: 'uniquify'
    });

    setTimeout(() => {
      chrome.declarativeNetRequest.updateSessionRules({
        removeRuleIds: [RULE_ID]
      });
    }, 15000);

  } catch (error) {
    // Fallback: let Chrome fetch the URL directly (handles very large files that
    // are not hotlink-protected; a protected one may still fail here).
    try {
      const path = buildPath(subfolder, getFilename(videoUrl));
      enqueue(path);
      await chrome.downloads.download({
        url: videoUrl,
        filename: path,
        conflictAction: 'uniquify'
      });
    } catch (e) {}
  }
}

async function blobToDataUrl(blob) {
  const buffer = await blob.arrayBuffer();
  const bytes = new Uint8Array(buffer);

  let binary = '';
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
  }

  const type = blob.type || 'video/mp4';
  return `data:${type};base64,${btoa(binary)}`;
}

async function getSubfolder(referer, title) {
  const { subfolder } = await chrome.storage.sync.get('subfolder');
  let pattern = (subfolder || '').trim();
  if (!pattern) return '';

  let domain = '';
  try {
    domain = new URL(referer).hostname;
  } catch {}

  const safeTitle = (title || '').replace(/[\\/]+/g, ' ').trim().slice(0, 100);

  pattern = pattern
    .replace(/\{domain\}/g, domain)
    .replace(/\{title\}/g, safeTitle);

  return sanitizePath(pattern);
}

function sanitizePath(path) {
  return path
    .split(/[\\/]+/)
    .map(sanitizeSegment)
    .filter(Boolean)
    .join('/');
}

function sanitizeSegment(segment) {
  const cleaned = segment
    .replace(/[<>:"|?*\x00-\x1f]/g, '_')
    .replace(/[. ]+$/, '')
    .trim();
  return /^\.+$/.test(cleaned) ? '' : cleaned;
}

function buildPath(subfolder, filename) {
  const leaf = sanitizeSegment(filename.replace(/[\\/]+/g, '_')) || `video_${Date.now()}.mp4`;
  return subfolder ? `${subfolder}/${leaf}` : leaf;
}

function getFilename(url) {
  try {
    const pathname = new URL(url).pathname;
    const name = decodeURIComponent(pathname.split('/').pop() || '');
    if (name && /\.(mp4|webm|mkv|mov|m4v|avi|ts|m3u8)$/i.test(name)) {
      return name;
    }
    if (name && name.includes('.')) {
      return name;
    }
    return `video_${Date.now()}.mp4`;
  } catch {
    return `video_${Date.now()}.mp4`;
  }
}
