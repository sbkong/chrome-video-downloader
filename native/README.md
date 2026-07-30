# Native host (bundled yt-dlp) for Video Downloader

The extension does not download video itself. It hands the current page URL to a
local native messaging host, which runs **yt-dlp** (+ **ffmpeg** for merging) and
saves the file. This is what makes real sites work — Vimeo, most HLS/DASH
players, and the 1000+ sites yt-dlp supports.

**No tools to install.** `yt-dlp.exe` and `ffmpeg.exe` are bundled in `bin\`, and
the host runs on Windows' built-in PowerShell. You only register it once.

## Install

1. Load the extension: `chrome://extensions` -> Developer mode -> **Load
   unpacked** -> the `video-downloader` folder.
2. **Double-click `install.bat`** in this folder.
3. Reload the extension.

No extension ID to copy (it is fixed by the manifest `key`). `install.bat` writes
`com.sbk.ytdlp.json` and registers the host for Chrome and Edge (current user).

To remove: double-click `uninstall.bat`.

## Use

- On a video page: **Ctrl + Alt + Click** the video, or open the toolbar popup and
  click **Download this page**.
- Toolbar badge shows progress (`%`) then `OK` / `ERR`; the popup shows a progress
  bar and the saved file name.
- Set a **Save folder** (absolute path) in the popup; empty = your Downloads
  folder.

## Files

| File | Purpose |
|------|---------|
| `bin\yt-dlp.exe`, `bin\ffmpeg.exe` | Bundled download engine + muxer (no install needed). |
| `host.ps1` | PowerShell native messaging host; runs yt-dlp, streams progress. |
| `host.bat` | Launcher registered with the browser (runs host.ps1). |
| `install.bat` / `install.ps1` | Register the host (Chrome + Edge, current user). |
| `uninstall.bat` / `uninstall.ps1` | Unregister. |
| `fetch-binaries.ps1` | Maintainer tool: (re)download `bin\` binaries / update yt-dlp. |
| `com.sbk.ytdlp.json` | Generated native host manifest. |

## Staying current

`yt-dlp` needs frequent updates as sites change. The host handles this
automatically: at most once every 24 hours (before a download) it runs yt-dlp's
built-in self-update (`yt-dlp.exe -U`). No user action needed; if there's no
network it just logs and continues. A timestamp marker `bin\.last_update`
throttles the check. `ffmpeg` rarely needs updating; run `fetch-binaries.ps1` to
refresh it.

## Notes / limits

- Windows only (uses PowerShell + `.bat`). macOS/Linux would need a shell host.
- The host still must be **registered once per machine** (`install.bat`) — a
  browser extension cannot launch a local program without this.
- `bin\` is ~115 MB (mostly ffmpeg). To rebuild it, run `fetch-binaries.ps1`.
- Downloading may violate a site's Terms of Service; use responsibly.
