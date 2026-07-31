const t = (key) => chrome.i18n.getMessage(key);

document.title = t('actionTitle');
document.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
document.querySelectorAll('[data-i18n-html]').forEach((el) => { el.innerHTML = t(el.dataset.i18nHtml); });
document.querySelectorAll('[data-i18n-ph]').forEach((el) => { el.placeholder = t(el.dataset.i18nPh); });
document.querySelectorAll('[data-i18n-title]').forEach((el) => { el.title = t(el.dataset.i18nTitle); });

const listEl = document.getElementById('list');
let activeTab = null;

// Tabs: Videos / Settings
document.querySelectorAll('.tab').forEach((tab) => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach((x) => x.classList.toggle('active', x === tab));
    document.querySelectorAll('.tabpane').forEach((p) => { p.hidden = (p.id !== 'tab-' + tab.dataset.tab); });
  });
});

// "Download selected" is a trigger: it starts every checked, not-yet-downloaded
// row. Each downloads by its own URL (its own filename); it never becomes "open
// folder". The header checkbox selects/clears all rows at once.
const pageBtn = document.getElementById('downloadPage');
const selectAll = document.getElementById('selectAll');

pageBtn.addEventListener('click', () => {
  [...listEl.querySelectorAll('li')].forEach((li) => {
    const c = li.querySelector('input.sel');
    const b = li.querySelector('button');
    if (c && c.checked && !c.disabled && b && b.dataset.state === 'idle') onButton(b);
  });
});

selectAll.addEventListener('change', () => {
  selectableChecks().forEach((c) => { c.checked = selectAll.checked; });
  updateSelectionUI();
});

// Checkboxes that can still be toggled (a downloading/finished row is locked).
function selectableChecks() {
  return [...listEl.querySelectorAll('input.sel')].filter((c) => !c.disabled);
}

function rowCheck(btn) {
  const li = btn.closest && btn.closest('li');
  return li ? li.querySelector('input.sel') : null;
}

function updateSelectionUI() {
  const checks = selectableChecks();
  const checked = checks.filter((c) => c.checked);
  selectAll.checked = checks.length > 0 && checked.length === checks.length;
  selectAll.indeterminate = checked.length > 0 && checked.length < checks.length;
  selectAll.disabled = checks.length === 0;
  pageBtn.disabled = checked.length === 0;
}

function currentTab() {
  return new Promise((resolve) => chrome.tabs.query({ active: true, currentWindow: true }, (x) => resolve(x && x[0])));
}

function getContentVideos(tabId) {
  return new Promise((resolve) => {
    chrome.tabs.sendMessage(tabId, { action: 'listVideos' }, (resp) => {
      void chrome.runtime.lastError;
      resolve(resp || { videos: [], streamThumb: '' });
    });
  });
}

function getStreamManifests(tabId) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage({ action: 'getMedia', tabId }, (arr) => {
      void chrome.runtime.lastError;
      resolve(arr || []);
    });
  });
}

async function loadVideos(verify) {
  activeTab = await currentTab();
  listEl.innerHTML = '';
  if (!activeTab) return;
  const [content, manifests] = await Promise.all([
    getContentVideos(activeTab.id),
    getStreamManifests(activeTab.id)
  ]);
  const direct = content.videos || [];
  // Each stream manifest (.m3u8/.mpd) the page fetched is its own real video.
  const streams = manifests.map((m) => {
    let label;
    try { label = decodeURIComponent(new URL(m.url).pathname.split('/').pop() || m.url); } catch (e) { label = m.url; }
    return { url: m.url, kind: 'stream', label: label, dim: '', thumb: content.streamThumb || '' };
  });
  const items = [...direct, ...streams];
  // Always offer "extract this page with yt-dlp". This is how real sites (Vimeo,
  // etc.) whose player lives in a cross-origin iframe / uses a protected stream
  // get downloaded — yt-dlp has a site-specific extractor for the page URL.
  if (activeTab.url && /^https?:/i.test(activeTab.url)) {
    items.push({ url: activeTab.url, kind: 'page', label: activeTab.title || activeTab.url, dim: '', thumb: '' });
  }
  render(items);
  hydrateFromBackground(verify);
}

// Reflect downloads already known to the background (started here earlier, or from
// the on-page badge), keyed by URL so both UIs stay in sync. Opening the popup
// uses the cheap cached state; only the refresh button (verify=true) asks the host
// to check disk and drop finished files the user has since deleted.
function hydrateFromBackground(verify) {
  chrome.runtime.sendMessage({ action: verify ? 'verifyDownloads' : 'getDownloads' }, (map) => {
    void chrome.runtime.lastError;
    if (map) Object.keys(map).forEach((url) => onStatus(map[url]));
  });
}

// A video row: [checkbox] [thumb] [meta] [status-label] [button(다운로드→진행중→폴더 열기)]
function makeRow(label, kindLabel, kindClass, url, thumb) {
  const li = document.createElement('li');

  const check = document.createElement('input');
  check.type = 'checkbox';
  check.className = 'sel';
  check.checked = false;
  check.addEventListener('change', updateSelectionUI);

  const thumbEl = document.createElement(thumb ? 'img' : 'span');
  thumbEl.className = 'thumb';
  if (thumb) thumbEl.src = thumb;

  const meta = document.createElement('div');
  meta.className = 'meta';
  const kind = document.createElement('span');
  kind.className = 'kind ' + kindClass;
  kind.textContent = kindLabel;
  const name = document.createElement('span');
  name.className = 'name';
  name.textContent = label;
  name.title = url;
  meta.appendChild(kind);
  meta.appendChild(name);

  const status = document.createElement('span');
  status.className = 'rowStatus';

  const btn = document.createElement('button');
  btn.className = 'small';
  btn.textContent = t('dlBtn');
  btn.dataset.url = url;
  btn.dataset.state = 'idle';
  btn._status = status;
  btn._label = t('dlBtn');
  btn.addEventListener('click', () => onButton(btn));

  // Checkbox + text share one <label> so clicking the name toggles selection too.
  const pick = document.createElement('label');
  pick.className = 'pick';
  pick.appendChild(check);
  pick.appendChild(thumbEl);
  pick.appendChild(meta);

  li.appendChild(pick);
  li.appendChild(status);
  li.appendChild(btn);
  listEl.appendChild(li);
  return btn;
}

function onButton(btn) {
  if (btn.dataset.state === 'done') {
    if (btn.dataset.path) chrome.runtime.sendMessage({ action: 'reveal', path: btn.dataset.path });
    return;
  }
  if (btn.dataset.state === 'downloading') return;
  // Optimistic; the background's URL-keyed status will confirm and drive updates.
  applyStatus(btn, { state: 'downloading', percent: null });
  chrome.runtime.sendMessage({
    action: 'download',
    url: btn.dataset.url,
    referer: activeTab ? activeTab.url : '',
    title: activeTab ? activeTab.title : '',
    tabId: activeTab ? activeTab.id : undefined
  });
}

// All row buttons pointing at a given download URL (usually one).
function buttonsForUrl(url) {
  return [...listEl.querySelectorAll('button')].filter((b) => b.dataset.url === url);
}

// Apply a status object to one button (download -> % -> open folder / error).
function applyStatus(btn, s) {
  const c = rowCheck(btn);
  if (s.state === 'queued' || s.state === 'starting' || s.state === 'downloading') {
    btn.disabled = true;
    btn.dataset.state = 'downloading';
    btn.classList.remove('done');
    btn.textContent = t('stDownloading');
    if (c) { c.checked = false; c.disabled = true; }
    if (btn._status) {
      btn._status.classList.remove('err');
      btn._status.textContent = (typeof s.percent === 'number') ? Math.round(s.percent) + '%' : '';
    }
  } else if (s.state === 'done') {
    btn.disabled = false;
    btn.dataset.state = 'done';
    btn.dataset.path = s.path || '';
    btn.classList.add('done');
    btn.textContent = t('openFolderBtn');
    if (c) { c.checked = false; c.disabled = true; }
    if (btn._status) { btn._status.classList.remove('err'); btn._status.textContent = '100%'; }
  } else if (s.state === 'error') {
    btn.disabled = false;
    btn.dataset.state = 'idle';
    btn.classList.remove('done');
    btn.textContent = btn._label;
    if (c) { c.disabled = false; }
    if (btn._status) {
      btn._status.classList.add('err');
      btn._status.textContent = (s.message || t('stError')) + (s.hostMissing ? ' ' + t('hostMissingHint') : '');
    }
  }
  updateSelectionUI();
}

function onStatus(s) {
  if (!s || !s.url) return;
  buttonsForUrl(s.url).forEach((b) => applyStatus(b, s));
}

function render(videos) {
  listEl.innerHTML = '';
  videos.forEach((v) => {
    const label = v.label + (v.dim ? '  (' + v.dim + ')' : '');
    const kindLabel = v.kind === 'direct' ? 'FILE' : (v.kind === 'stream' ? 'STREAM' : 'PAGE');
    const kindClass = v.kind === 'direct' ? 'direct' : (v.kind === 'page' ? 'page' : '');
    makeRow(label, kindLabel, kindClass, v.url, v.thumb);
  });
  if (!videos.length) {
    const li = document.createElement('li'); li.className = 'empty'; li.textContent = t('noVideos'); listEl.appendChild(li);
  }
  updateSelectionUI();
}

document.getElementById('refresh').addEventListener('click', () => loadVideos(true));

// Settings: save folder + click shortcut + cookies. The shortcut is captured by
// holding modifier keys and left/right-clicking the field, and auto-saves so it
// applies immediately (no separate Save needed).
const savePathInput = document.getElementById('savePath');
const useCookiesInput = document.getElementById('useCookies');
const shortcutEnabledInput = document.getElementById('shortcutEnabled');
const badgeEnabledInput = document.getElementById('badgeEnabled');
const captureEl = document.getElementById('shortcutCapture');
const saveStatus = document.getElementById('saveStatus');

// The on-video hover button toggle applies immediately (auto-save).
badgeEnabledInput.addEventListener('change', () => {
  chrome.storage.sync.set({ badgeEnabled: badgeEnabledInput.checked });
});

const MOD_ORDER = ['ctrl', 'alt', 'shift', 'meta'];
const MOD_LABEL = { ctrl: 'Ctrl', alt: 'Alt', shift: 'Shift', meta: 'Meta' };
const comboLabel = (mods) => mods.map((m) => MOD_LABEL[m]).join(' + ');
const modsFromEvent = (e) => MOD_ORDER.filter((m) => ({ ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, meta: e.metaKey })[m]);

let clickModMods = ['ctrl', 'alt'];
let clickButton = 'left';
let flashTimer = null;

const buttonLabel = () => t(clickButton === 'right' ? 'clickRight' : 'clickLeft');
const fullLabel = () => comboLabel(clickModMods) + ' + ' + buttonLabel();

function renderShortcut() {
  const enabled = shortcutEnabledInput.checked;
  captureEl.classList.toggle('disabled', !enabled);
  captureEl.classList.remove('capturing');
  captureEl.textContent = clickModMods.length ? fullLabel() : t('shortcutCapturePlaceholder');
  const usageEl = document.querySelector('.usage');
  if (usageEl) {
    usageEl.textContent = (enabled && clickModMods.length)
      ? t('usage').replace('{combo}', fullLabel())
      : t('usageNoShortcut');
  }
}

function persistShortcut() {
  chrome.storage.sync.set({ clickMod: clickModMods.join('+'), clickButton: clickButton, shortcutEnabled: shortcutEnabledInput.checked });
}

// One-shot capture: hold the modifier(s) and left/right-click the field.
captureEl.addEventListener('mousedown', (e) => {
  if (!shortcutEnabledInput.checked) return;
  e.preventDefault();
  if (e.button === 1) return; // ignore middle click
  const mods = modsFromEvent(e);
  if (!mods.length) { // a modifier is required — keep the current value, hint briefly
    captureEl.classList.add('capturing');
    captureEl.textContent = t('shortcutCaptureActive');
    clearTimeout(flashTimer);
    flashTimer = setTimeout(renderShortcut, 1300);
    return;
  }
  clickModMods = mods;
  clickButton = (e.button === 2) ? 'right' : 'left';
  renderShortcut();
  persistShortcut();
});
captureEl.addEventListener('contextmenu', (e) => e.preventDefault()); // capture right-click without a menu
shortcutEnabledInput.addEventListener('change', () => { renderShortcut(); persistShortcut(); });

chrome.storage.sync.get(['savePath', 'clickMod', 'clickButton', 'shortcutEnabled', 'badgeEnabled', 'useCookies'], ({ savePath, clickMod, clickButton: cb, shortcutEnabled, badgeEnabled, useCookies }) => {
  savePathInput.value = savePath || '';
  clickModMods = (clickMod || 'ctrl+alt').split('+').filter(Boolean);
  clickButton = cb || 'left';
  shortcutEnabledInput.checked = (shortcutEnabled !== false); // default on
  badgeEnabledInput.checked = (badgeEnabled !== false);       // default on
  useCookiesInput.checked = !!useCookies;
  renderShortcut();
});

document.getElementById('save').addEventListener('click', () => {
  chrome.storage.sync.set({
    savePath: savePathInput.value.trim(),
    useCookies: useCookiesInput.checked
  }, () => {
    saveStatus.textContent = t('savedStatus');
    setTimeout(() => { saveStatus.textContent = ''; }, 1500);
  });
});
savePathInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') document.getElementById('save').click(); });

chrome.runtime.onMessage.addListener((msg) => { if (msg && msg.action === 'status') onStatus(msg.status); });
loadVideos();
