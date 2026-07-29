# Video Downloader

A Chrome (Manifest V3) extension that downloads videos with Ctrl+Alt+Click,
including on pages that try to block saving through right-click menus, drag
blocking, or hotlink (Referer) protection.

## Capabilities

- Ctrl+Alt+Click a video to download it immediately.
- Sees through anti-save tricks:
  - Right-click, drag, and selection blocking are irrelevant because the
    extension acts on a Ctrl+Alt+Click captured before the page's own handlers.
  - Resolves the source URL from a `<video>` element (`currentSrc` or `src`),
    from a nested `<source>`, and from the element stack at the click point so
    overlays on top of the video do not prevent detection.
- Bypasses hotlink protection by fetching the video with the page URL set as the
  `Referer` header (via `declarativeNetRequest`), so videos that only load with a
  valid referrer still download.
- Chooses the filename and destination reliably through
  `chrome.downloads.onDeterminingFilename`.
- Configurable subfolder inside the Downloads directory, with dynamic tokens:
  - `{domain}` is replaced with the source page's domain.
  - `{title}` is replaced with the source page's title.
  - Tokens can be combined and nested, for example `{domain}/{title}`.
  - Leave the field empty to save directly into the Downloads root.
- Automatic filename de-duplication (Chrome's `uniquify` conflict action).
- Multilingual UI (English, Korean, Chinese) selected automatically from the
  browser language.

## Installation

1. Open `chrome://extensions`.
2. Enable Developer mode (top right).
3. Click "Load unpacked" and select this folder (`video-downloader`).
4. Optional: open the toolbar puzzle icon and pin the extension for quick
   access to its settings.

## Usage

1. Click the extension's toolbar icon to open the settings popup.
2. Set the subfolder name (or leave it empty). Examples:
   - empty: saves to the Downloads root.
   - `{domain}`: saves to `Downloads/<site-domain>/`.
   - `{domain}/{title}`: saves to `Downloads/<site-domain>/<page-title>/`.
3. On any web page, hold Ctrl and Alt and click a video to download it.

Note: Ctrl+Alt+Click is used (not Shift) so the browser does not extend a text
selection, and it does not overlap with the companion Image Downloader extension
(which uses Alt+Click).

## Settings

The subfolder value is stored with `chrome.storage.sync`, so it follows your
Chrome profile across signed-in devices. Path segments are sanitized: characters
that are illegal on Windows/macOS are replaced, trailing dots and spaces are
trimmed, and directory traversal (`..`) is neutralized.

## Localization

UI strings live in `_locales/<lang>/messages.json` for `en`, `ko`, and `zh`, and
are referenced from the manifest with `__MSG_*__` placeholders and from the popup
via `data-i18n` attributes. Chrome picks the language from the browser UI
language and falls back to English.

## Permissions

- `downloads`: save files and control the destination filename/subfolder.
- `storage`: persist the subfolder setting.
- `declarativeNetRequest`: set the `Referer` request header to bypass hotlink
  protection.
- `host_permissions: <all_urls>`: run the content script and fetch videos on any
  site the user visits.

## Limitations

- Works with direct video file URLs (for example `.mp4`, `.webm`). The video is
  fetched in the background and written via a data URL, which is fine for typical
  clips; if the fetch fails, it falls back to a direct download by URL.
- Streaming sources are not supported: blob URLs from Media Source Extensions
  (for example YouTube) and segmented streams such as HLS `.m3u8` cannot be saved
  as a single original file this way.
- Protected sources that require tokens or cookies (beyond Referer) may still
  fail.
- Files can only be saved inside the browser's Downloads directory; Chrome does
  not allow extensions to write to arbitrary absolute paths.

## License

Licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file
for details.
