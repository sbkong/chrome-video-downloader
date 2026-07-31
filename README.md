# Video Downloader

A Chrome (Manifest V3) extension that downloads videos from the current page with
a local **yt-dlp** + **ffmpeg** helper. The extension detects videos and forwards
a URL; a bundled native host does the actual download and merge. This makes real
sites work (HLS/DASH players, Vimeo, YouTube, and the many sites yt-dlp supports)
without fragile in-browser extraction.

## Setup

1. `chrome://extensions` -> enable Developer mode -> **Load unpacked** -> this folder.
2. Open the `native` folder and **double-click `install.bat`**, then reload the extension.

Nothing else to install: `yt-dlp.exe` and `ffmpeg.exe` are bundled in `native/bin`
and the host runs on built-in PowerShell. `install.bat` only registers the host so
the browser is allowed to launch it. See [`native/README.md`](native/README.md).

## How to use

Any of these:

- **Popup**: click the toolbar icon. It lists detected videos (files, streams, and
  a "PAGE" item for the whole page). Check items and use **Download selected**, or
  the per-row button. The button cycles Download -> % -> Open folder.
- **On-video button**: hover a video; a download button appears at its top-right
  and mirrors the popup state.
- **Shortcut**: a modifier + click on a video (default Ctrl + Alt + left click).

Downloads run one at a time. Finished files can be opened via **Open folder**;
the popup's refresh button re-checks whether a file still exists on disk.

## Settings (popup -> Settings tab)

- **Save folder**: absolute path, or relative to Downloads; empty = Downloads.
  Tokens `{domain}` and `{title}` become the site domain / video title.
- **Download shortcut**: enable/disable, and capture your own combo by holding the
  modifier keys and left/right-clicking the capture field.
- **Show download button on video**: toggle the on-video hover button.
- **Use browser cookies**: pass the logged-in Chrome session's cookies to yt-dlp
  for member-only / purchased videos (off by default).

## How it works

```
[page] --detect / click / popup--> [extension] --Native Messaging--> [host.ps1] --> yt-dlp + ffmpeg --> file
```

- Direct `http(s)` files are downloaded by their own URL.
- HLS/DASH streams are found by sniffing `.m3u8` / `.mpd` requests.
- The **PAGE** item hands the page URL to yt-dlp's site extractor.
- Output is mp4 (H.264 + AAC) to avoid webm/opus playback issues. The host sends a
  Referer for hotlink-protected files, keeps yt-dlp up to date, and falls back to a
  plain HTTP download if yt-dlp fails on a direct file. Logs: `native/logs`.

UI is available in English, Korean, and Chinese.

## Permissions

- `nativeMessaging`: talk to the local yt-dlp host.
- `storage`: remember settings.
- `activeTab`, `host_permissions`: read the active tab and current page URL.
- `webRequest`: observe `.m3u8` / `.mpd` requests to detect streams.

## Notes

- The native host is registered per machine (one double-click of `install.bat`).
- Downloading may violate a site's Terms of Service; use responsibly.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
