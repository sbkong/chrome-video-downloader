// Ctrl+Alt+Click anywhere (or on a video) hands the CURRENT PAGE URL to the
// local yt-dlp host via the background service worker. yt-dlp figures out the
// actual media from the page URL (works for MSE/DASH/HLS/Vimeo/etc.).
document.addEventListener('click', function (event) {
  if (!event.ctrlKey || !event.altKey) return;

  // Only act when the click is on/near a video, to avoid hijacking normal clicks.
  const onVideo = event.target && (
    event.target.tagName === 'VIDEO' ||
    (event.target.closest && event.target.closest('video')) ||
    document.elementsFromPoint(event.clientX, event.clientY).some((el) => el.tagName === 'VIDEO')
  );
  if (!onVideo) return;

  event.preventDefault();
  event.stopPropagation();

  try {
    chrome.runtime.sendMessage({ action: 'download', url: location.href });
  } catch (e) {}
}, true);
