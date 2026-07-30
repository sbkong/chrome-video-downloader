const t = (key) => chrome.i18n.getMessage(key);

document.title = t('actionTitle');
document.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
document.querySelectorAll('[data-i18n-html]').forEach((el) => { el.innerHTML = t(el.dataset.i18nHtml); });
document.querySelectorAll('[data-i18n-ph]').forEach((el) => { el.placeholder = t(el.dataset.i18nPh); });

// ---- Save path setting ----
const savePathInput = document.getElementById('savePath');
const saveStatus = document.getElementById('saveStatus');

chrome.storage.sync.get('savePath', ({ savePath }) => { savePathInput.value = savePath || ''; });

document.getElementById('save').addEventListener('click', () => {
  chrome.storage.sync.set({ savePath: savePathInput.value.trim() }, () => {
    saveStatus.textContent = t('savedStatus');
    setTimeout(() => { saveStatus.textContent = ''; }, 1500);
  });
});

// ---- Download current page ----
document.getElementById('download').addEventListener('click', () => {
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    const tab = tabs && tabs[0];
    if (!tab) return;
    chrome.runtime.sendMessage({ action: 'download', url: tab.url });
  });
});

// ---- Live status ----
const dlEl = document.getElementById('dlstatus');

function renderStatus(s) {
  dlEl.className = 'dlstatus';
  if (!s) { dlEl.textContent = ''; return; }
  if (s.state === 'starting') {
    dlEl.textContent = t('stStarting');
  } else if (s.state === 'downloading') {
    const pct = (typeof s.percent === 'number') ? Math.round(s.percent) + '%' : '';
    dlEl.textContent = t('stDownloading') + ' ' + pct;
    const bar = document.createElement('div');
    bar.className = 'bar';
    const i = document.createElement('i');
    i.style.width = (typeof s.percent === 'number' ? s.percent : 0) + '%';
    bar.appendChild(i);
    dlEl.appendChild(bar);
  } else if (s.state === 'done') {
    dlEl.classList.add('done');
    dlEl.textContent = t('stDone') + (s.file ? ': ' + s.file : '');
  } else if (s.state === 'error') {
    dlEl.classList.add('err');
    dlEl.textContent = t('stError') + ': ' + (s.message || '') + (s.hostMissing ? '\n' + t('hostMissingHint') : '');
  }
}

chrome.runtime.sendMessage({ action: 'getStatus' }, (s) => renderStatus(s));
chrome.runtime.onMessage.addListener((msg) => {
  if (msg && msg.action === 'status') renderStatus(msg.status);
});
