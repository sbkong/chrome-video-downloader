# Downloads the bundled binaries (yt-dlp.exe + static ffmpeg.exe) into bin\.
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

Get-ChildItem $bin | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
Write-Host 'Binaries ready in bin\.'
