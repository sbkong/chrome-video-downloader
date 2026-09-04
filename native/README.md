# Native host (bundled yt-dlp) for Video Downloader

The extension does not download video itself. It hands the current page URL to a
local native messaging host, which runs **yt-dlp** (+ **ffmpeg** for merging) and
saves the file. This is what makes real sites work — most HLS/DASH players, and
the 1000+ sites yt-dlp supports.

**No tools to install.** `yt-dlp.exe`, `ffmpeg.exe` and `deno.exe` are bundled in
`bin\`, and the host runs on Windows' built-in PowerShell. You only register it
once.

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
| `bin\deno.exe` | JavaScript runtime yt-dlp uses when a site's player JS has to be run. |
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
throttles the check. `ffmpeg` and `deno` rarely need updating; run
`fetch-binaries.ps1` to refresh them (it skips whichever is already present —
delete the file first to force a re-download).

Some sites need more than yt-dlp alone: their format URLs carry a parameter that
has to be computed by running the site's own JavaScript, so the host passes
`--js-runtimes deno:bin\deno.exe`; without a JS runtime yt-dlp drops those formats
and falls back to ones that fail with `HTTP Error 403: Forbidden`. For the same
reason the host pins a specific player client where yt-dlp's default choice
returns formats that also 403.

## Notes / limits

- Windows only (uses PowerShell + `.bat`). macOS/Linux would need a shell host.
- The host still must be **registered once per machine** (`install.bat`) — a
  browser extension cannot launch a local program without this.
- `bin\` is ~215 MB (mostly ffmpeg and deno). To rebuild it, run
  `fetch-binaries.ps1`.
- Downloading may violate a site's Terms of Service; use responsibly.
