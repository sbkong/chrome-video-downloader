document.addEventListener('click', async function(event) {
  // Ctrl + Alt + Click (Shift is avoided because Shift+Click extends the browser's
  // text selection, which grabbed a block instead of triggering a download).
  if (!event.ctrlKey || !event.altKey) return;

  const found = resolveVideoAt(event);
  if (!found) return;

  event.preventDefault();
  event.stopPropagation();

  flash(found.el);

  try {
    await chrome.runtime.sendMessage({
      action: 'downloadVideo',
      url: found.url,
      referer: window.location.href,
      title: document.title
    });
  } catch (error) {
  }
}, true);

// Resolve the video URL under the click point. Handles <video src>, nested
// <source>, and elements stacked over the video (overlays / anti-save layers).
function resolveVideoAt(event) {
  const stack = document.elementsFromPoint(event.clientX, event.clientY);

  for (const el of stack) {
    if (el.tagName === 'VIDEO') {
      const url = videoUrl(el);
      if (url) return { el, url };
    }
    if (el.tagName === 'SOURCE' && el.src) {
      return { el, url: el.src };
    }
  }

  // Fallback: nearest <video> ancestor of the actual target.
  const v = event.target.closest && event.target.closest('video');
  if (v) {
    const url = videoUrl(v);
    if (url) return { el: v, url };
  }

  return null;
}

function videoUrl(video) {
  let url = video.currentSrc || video.src;
  if (!url) {
    const source = video.querySelector('source[src]');
    if (source) url = source.src;
  }
  return url || null;
}

function flash(el) {
  if (!el || !el.style) return;
  const original = el.style.outline;
  el.style.outline = '3px solid #E53935';
  setTimeout(() => { el.style.outline = original; }, 500);
}
