const t = (key) => chrome.i18n.getMessage(key);

// Localize static UI from _locales via data-i18n* attributes.
document.title = t('actionTitle');
document.querySelectorAll('[data-i18n]').forEach((el) => {
  el.textContent = t(el.dataset.i18n);
});
document.querySelectorAll('[data-i18n-html]').forEach((el) => {
  el.innerHTML = t(el.dataset.i18nHtml);
});
document.querySelectorAll('[data-i18n-ph]').forEach((el) => {
  el.placeholder = t(el.dataset.i18nPh);
});

const input = document.getElementById('subfolder');
const status = document.getElementById('status');

chrome.storage.sync.get('subfolder', ({ subfolder }) => {
  input.value = subfolder || '';
});

document.getElementById('save').addEventListener('click', () => {
  chrome.storage.sync.set({ subfolder: input.value.trim() }, () => {
    status.textContent = t('savedStatus');
    setTimeout(() => { status.textContent = ''; }, 1500);
  });
});

input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') document.getElementById('save').click();
});
