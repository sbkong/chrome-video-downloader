# Registers the bundled yt-dlp native messaging host for the Video Downloader
# extension. No Python / ffmpeg / yt-dlp install needed — yt-dlp.exe and
# ffmpeg.exe (plus deno.exe, the JS runtime yt-dlp needs on some sites) are bundled
# in bin\, and the host runs on built-in PowerShell.
#
# Easiest: double-click install.bat. The extension IDs are known ahead of time, so
# nothing needs to be supplied. Override only if you repackage:
#   .\install.ps1 -ExtensionId <id>[,<id>...]
#
# allowed_origins is a LIST, so one host registration can serve several builds of
# the extension. That is what lets a single installer cover both the unpacked
# development build (its ID pinned by the manifest "key") and the published Web
# Store build (its ID assigned by Google on first upload) - no second installer,
# no re-registering when switching between them.
param(
  [string[]]$ExtensionId = @(
    'epcfbadpbldealfmaohachdoiljkidhk'   # development / unpacked build
    # 'STORE_ID_GOES_HERE'               # Chrome Web Store build: paste the ID after the first upload
  )
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostName = 'com.sbk.ytdlp'
$hostBat = Join-Path $here 'host.bat'

# deno is needed on sites whose player JS yt-dlp has to run, so a pre-deno install
# of bin\ is refreshed here too.
if (-not (Test-Path (Join-Path $here 'bin\yt-dlp.exe')) -or -not (Test-Path (Join-Path $here 'bin\deno.exe'))) {
  Write-Host 'Bundled binaries incomplete. Fetching...'
  & (Join-Path $here 'fetch-binaries.ps1')
}
if (-not (Test-Path (Join-Path $here 'bin\ffmpeg.exe'))) {
  Write-Host 'WARNING: bin\ffmpeg.exe not found — audio+video merge may fail. Run fetch-binaries.ps1.'
}
if (-not (Test-Path (Join-Path $here 'bin\deno.exe'))) {
  Write-Host 'WARNING: bin\deno.exe not found — some sites will fail with HTTP 403. Run fetch-binaries.ps1.'
}

# "powershell -File script.ps1 -ExtensionId a,b" hands the parameter over as the
# single literal string "a,b" - with -File, arguments are not parsed as PowerShell
# expressions. install.bat and the installer both invoke it that way, so split on
# commas before validating rather than quietly seeing one nonsense ID.
$ExtensionId = @($ExtensionId | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ })

# Drop anything that is not a real extension ID (32 letters a-p), so a commented
# placeholder that gets uncommented too early cannot produce a manifest Chrome
# will silently refuse.
$ids = @($ExtensionId | Where-Object { $_ -match '^[a-p]{32}$' })
if (-not $ids.Count) {
  Write-Host 'ERROR: no valid extension ID. An ID is 32 letters in the range a-p.'
  Write-Host "  got: $($ExtensionId -join ', ')"
  exit 1
}
$skipped = @($ExtensionId | Where-Object { $_ -notmatch '^[a-p]{32}$' })
if ($skipped.Count) { Write-Host "Ignoring invalid extension ID(s): $($skipped -join ', ')" }

# Native messaging host manifest -> points Chrome/Edge at host.bat
$manifest = [ordered]@{
  name            = $hostName
  description     = 'yt-dlp download host for Video Downloader'
  path            = $hostBat
  type            = 'stdio'
  allowed_origins = @($ids | ForEach-Object { 'chrome-extension://' + $_ + '/' })
}
$manifestPath = Join-Path $here ($hostName + '.json')
# Must be BOM-less UTF-8: Windows PowerShell's -Encoding utf8 emits a BOM, which
# Chrome rejects when parsing the native host manifest.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), $utf8NoBom)
Write-Host "Wrote $manifestPath"

$chromeKey = 'HKCU\Software\Google\Chrome\NativeMessagingHosts\' + $hostName
$edgeKey   = 'HKCU\Software\Microsoft\Edge\NativeMessagingHosts\' + $hostName
foreach ($key in @($chromeKey, $edgeKey)) {
  & reg.exe add $key /ve /t REG_SZ /d $manifestPath /f | Out-Null
  Write-Host "Registered $key"
}

Write-Host ''
Write-Host "Done. Native host '$hostName' registered for $($ids.Count) extension ID(s):"
$ids | ForEach-Object { Write-Host "  $_" }
Write-Host 'Reload the extension if it was already running, then use Ctrl+Alt+Click on a video.'
