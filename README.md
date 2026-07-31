# Video Downloader

A Chrome (Manifest V3) extension that downloads videos from a page using a local
**yt-dlp** + **ffmpeg** helper. The extension detects videos and forwards a URL; a
bundled native host does the actual download and merge — so real sites work
(HLS/DASH players, Vimeo, YouTube, and the many sites yt-dlp supports).

## Install

1. `chrome://extensions` -> enable Developer mode -> **Load unpacked** -> this folder.
2. Open the `native` folder and **double-click `install.bat`**, then reload the extension.

Nothing else to install: `yt-dlp.exe` and `ffmpeg.exe` are bundled in `native/bin`
and the host runs on built-in PowerShell. See [`native/README.md`](native/README.md).

## Usage

Three ways to download, plus a Settings tab, all in the popup (toolbar icon). The
popup has two tabs: **Videos** and **Settings**. Downloads run one at a time.

### 1. Shortcut (modifier + click on a video)

- Default: **Ctrl + Alt + left click** a video to download it.
- For a plain file it grabs that file; for a blob/streaming player it uses the
  captured manifest, or the page URL so yt-dlp's site extractor handles it.
- Change the combo in **Settings**.

### 2. On-video button (hover)

- Hover a video; a red **download** button appears at its top-right.
- Click it: it shows **%** while downloading, then becomes **Open folder** (click
  to reveal the file). It stays visible while downloading / when done.
- Turn it off in Settings ("Show download button on video").

### 3. Popup list (Videos tab)

- Open the popup -> **Videos** tab lists what was found:
  - **FILE** — a direct video file on the page.
  - **STREAM** — an HLS/DASH manifest (`.m3u8` / `.mpd`) the page fetched. Play the
    video first so it gets detected, then hit Refresh.
  - **PAGE** — hand the whole page URL to yt-dlp's site extractor (use this for
    YouTube/Vimeo etc., whose player is in a cross-origin iframe).
- Check items and **Download selected**, or use a row's own button (Download -> %
  -> Open folder).
- **Refresh** re-scans; it also drops finished entries whose file you deleted.

### Settings tab

- **Save folder / path**: absolute path, or relative to Downloads; empty = Downloads.
  Tokens `{domain}` and `{title}` become the site domain / video title (e.g.
  `{domain}/{title}`). Press **Save**.
- **Use download shortcut**: enable/disable the click shortcut.
- **Set the combo**: click the capture box while **holding the modifier keys** and
  **left- or right-click** it — that exact combo is saved immediately.
- **Show download button on video**: toggle the hover button.
- **Use browser cookies**: pass your logged-in Chrome cookies to yt-dlp for
  member-only / purchased videos (off by default).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
