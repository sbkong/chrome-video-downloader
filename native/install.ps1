# Registers the bundled yt-dlp native messaging host for the Video Downloader
# extension. No Python / ffmpeg / yt-dlp install needed — yt-dlp.exe and
# ffmpeg.exe (plus deno.exe, the JS runtime yt-dlp needs on some sites) are bundled
# in bin\, and the host runs on built-in PowerShell.
#
# Easiest: double-click install.bat. The extension ID is fixed by the manifest
# "key", so no ID needs to be supplied. Override only if you repackage:
#   .\install.ps1 -ExtensionId <id>

param(
  [string]$ExtensionId = 'epcfbadpbldealfmaohachdoiljkidhk'
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

# Native messaging host manifest -> points Chrome/Edge at host.bat
$manifest = [ordered]@{
  name            = $hostName
  description     = 'yt-dlp download host for Video Downloader'
  path            = $hostBat
  type            = 'stdio'
  allowed_origins = @('chrome-extension://' + $ExtensionId + '/')
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
Write-Host "Done. Native host '$hostName' registered for extension $ExtensionId."
Write-Host 'Reload the extension if it was already running, then use Ctrl+Alt+Click on a video.'
