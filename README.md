# Video Downloader

A Chrome (Manifest V3) extension that downloads the video on the current page by
handing the page URL to a local **yt-dlp** native host. The extension itself does
not fetch media — a local helper (`native/host.py`) runs yt-dlp + ffmpeg to
extract, decode, merge, and save. This makes real sites work: Vimeo, most
HLS/DASH players, and the 1000+ sites yt-dlp supports.

## Architecture

```
[web page] --Ctrl+Alt+Click / popup--> [extension] --Native Messaging--> [host.py] --> yt-dlp + ffmpeg --> file
```

- **Extension**: only forwards the page URL and a save folder; shows progress.
- **Native host**: does the actual download/merge with yt-dlp.

## Capabilities

- Download the current page's video from a video page, via **Ctrl+Alt+Click** on
  the video or the popup's **Download this page** button.
- Works with MSE/DASH/HLS players and proprietary formats (Vimeo, etc.) because
  yt-dlp does the extraction — not fragile in-browser sniffing.
- Highest quality + audio + subtitles + large files (handled by yt-dlp/ffmpeg,
  not browser memory).
- Configurable **save folder** (absolute path); empty = system Downloads.
- Toolbar badge shows progress (`%`), then `OK` / `ERR`; popup shows a progress
  bar and the saved file name.
- Multilingual UI (English, Korean, Chinese).

## Setup (2 steps, nothing to install)

1. `chrome://extensions` -> Developer mode -> **Load unpacked** -> this folder.
2. Open the `native` folder and **double-click `install.bat`**, then reload the
   extension.

No Python / ffmpeg / yt-dlp to install — `yt-dlp.exe` and `ffmpeg.exe` are
bundled in `native/bin`, and the host runs on built-in PowerShell. No extension
ID to copy (fixed by the manifest `key`). The one unavoidable step is
`install.bat`, which registers the host (a browser extension cannot launch a
local program without this). See [`native/README.md`](native/README.md).

## Usage

- Open a video page, then **Ctrl+Alt+Click** the video (or use the popup button).
- Set the save folder in the popup if you want a specific location.

## Permissions

- `nativeMessaging`: talk to the local yt-dlp host.
- `storage`: remember the save folder.
- `activeTab`: read the current tab's URL when you trigger a download.

## Limits / notes

- The **native host must be installed per machine** (Python, ffmpeg, yt-dlp).
- Downloading may violate a site's Terms of Service; use responsibly.
- Chrome Web Store forbids in-extension YouTube downloading; the "extension
  forwards a URL, a local app downloads" split is why this design exists, but
  distribution/policy remains your responsibility.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
