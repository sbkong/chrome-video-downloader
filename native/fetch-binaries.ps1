# Downloads the bundled binaries (yt-dlp.exe + static ffmpeg.exe + deno.exe, the
# JavaScript runtime yt-dlp needs for YouTube) into bin\.
# For maintainers: run once to (re)build the bundle or to update yt-dlp.
#   .\fetch-binaries.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin = Join-Path $here 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null

Write-Host 'Downloading yt-dlp.exe...'
Invoke-WebRequest -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' `
  -OutFile (Join-Path $bin 'yt-dlp.exe') -TimeoutSec 300

if (-not (Test-Path (Join-Path $bin 'ffmpeg.exe'))) {
  Write-Host 'Downloading ffmpeg (static, ~100MB)...'
  $tmp = Join-Path $env:TEMP ('ffdl_' + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'ffmpeg.zip'
  Invoke-WebRequest -Uri 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' `
    -OutFile $zip -TimeoutSec 580
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $ff = Get-ChildItem -Path $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
  Copy-Item $ff.FullName -Destination (Join-Path $bin 'ffmpeg.exe') -Force
  Remove-Item -Recurse -Force $tmp
}

if (-not (Test-Path (Join-Path $bin 'deno.exe'))) {
  # yt-dlp needs a JavaScript runtime to solve YouTube's "n"/signature challenges;
  # without one its YouTube downloads fall back to formats that 403. deno is the
  # runtime yt-dlp supports out of the box (~95MB).
  Write-Host 'Downloading deno (JS runtime for YouTube, ~40MB zip)...'
  $tmp = Join-Path $env:TEMP ('denodl_' + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'deno.zip'
  Invoke-WebRequest -Uri 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' `
    -OutFile $zip -TimeoutSec 580
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $dn = Get-ChildItem -Path $tmp -Recurse -Filter deno.exe | Select-Object -First 1
  Copy-Item $dn.FullName -Destination (Join-Path $bin 'deno.exe') -Force
  Remove-Item -Recurse -Force $tmp
}

Get-ChildItem $bin | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
Write-Host 'Binaries ready in bin\.'
