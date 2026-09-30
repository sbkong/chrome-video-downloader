# Native host (yt-dlp) for Video Downloader

The extension does not download video itself. It hands a URL to a local native
messaging host, which runs **yt-dlp** (+ **ffmpeg** for merging) and saves the
file. This is what makes real sites work — most HLS/DASH players, and the 1000+
sites yt-dlp supports.

The host runs on Windows' built-in PowerShell. The three binaries it drives are
not committed here; they are fetched from each project's own official releases,
either by the installer or by `fetch-binaries.ps1`.

## Install

**Users:** run the installer from
[Releases](https://github.com/sbkong/chrome-video-downloader/releases/latest). It
installs per-user (no administrator rights, no UAC prompt), registers the host
for Chrome and Edge, and fetches the binaries. Uninstall from Settings → Apps,
which removes the registry entries and everything it downloaded.

**From source:**

1. Load the extension: `chrome://extensions` → Developer mode → **Load unpacked**
   → the `video-downloader` folder.
2. **Double-click `install.bat`** in this folder.
3. Reload the extension.

`install.bat` writes `com.sbk.ytdlp.json` and registers it for the current user.
There is no extension ID to copy: the development build's ID is fixed by the
manifest `key`, and `allowed_origins` is a list, so one registration can cover
several builds of the extension (see the `$ExtensionId` parameter in
`install.ps1`). To remove: double-click `uninstall.bat`.

## Use

- On a video page: **Ctrl + Alt + Click** the video, or use the toolbar popup.
- The toolbar badge shows progress (`%`) then `OK` / `ERR`; the popup shows the
  percentage and the saved file name.
- Set a **Save folder** in the popup; empty = your Downloads folder.

## Files

| File | Purpose |
|------|---------|
| `host.ps1` | PowerShell native messaging host; runs yt-dlp, streams progress. |
| `host.bat` | Launcher registered with the browser (runs host.ps1). |
| `install.bat` / `install.ps1` | Register the host (Chrome + Edge, current user). |
| `uninstall.bat` / `uninstall.ps1` | Unregister. |
| `fetch-binaries.ps1` | Download `bin\` binaries. Run by the installer, or by hand. |
| `installer\` | Inno Setup script for the distributed installer. |
| `bin\yt-dlp.exe` | The downloader. Fetched, not committed. |
| `bin\ffmpeg.exe` | Merges separate audio/video streams into one file. |
| `bin\deno.exe` | JavaScript runtime yt-dlp uses when a site's player JS must run. |
| `com.sbk.ytdlp.json` | Generated native host manifest. |

## Version policy

The three binaries are treated differently, because of **who calls them**.

**yt-dlp tracks the latest release.** It is the one this project invokes directly,
and it has to keep up with the sites it downloads from — a months-old copy simply
stops working. The host keeps it current on its own: at most once every 24 hours,
before a download, it runs `yt-dlp.exe -U`. No user action needed; with no network
it logs and continues. A timestamp marker `bin\.last_update` throttles the check.
After an update the host verifies the binary against the digest published for the
version it reports, and refuses to run it on a mismatch.

**ffmpeg and deno are pinned.** They are never called by us — yt-dlp invokes them,
with arguments we never see. Nothing about them needs to be new, and a new major
version is only a way for downloads that work today to break tomorrow. Both are
pinned in `fetch-binaries.ps1` to the exact build this project was tested against,
and verified against a SHA-256 committed in that file rather than one fetched from
the download site. That is the stronger check: a compromised or spoofed site can
serve a matching sidecar digest, but it cannot match a hash that already sits in
git. Moving a pin means changing the version, the URL and the hash together.

Some sites need more than yt-dlp alone: their format URLs carry a parameter that
has to be computed by running the site's own JavaScript, so the host passes
`--js-runtimes deno:bin\deno.exe`. Without a JS runtime yt-dlp drops those formats
and falls back to ones that fail with `HTTP Error 403: Forbidden`. For the same
reason the host pins a specific player client where yt-dlp's default choice
returns formats that also 403.

## Notes / limits

- Windows only (PowerShell + `.bat`). macOS/Linux would need a shell host.
- The host must be **registered once per machine** — a browser extension cannot
  launch a local program without this.
- `bin\` is ~208 MB once fetched, mostly ffmpeg and deno.
- Logs are written to `logs\`, with query-string secrets scrubbed and anything
  older than two weeks deleted at startup.
- Downloading may violate a site's Terms of Service; use responsibly.
