# Downloads the bundled binaries (yt-dlp.exe + static ffmpeg.exe + deno.exe, the
# JavaScript runtime yt-dlp needs on some sites) into bin\.
# For maintainers: run once to (re)build the bundle or to update yt-dlp.
#   .\fetch-binaries.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin = Join-Path $here 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null

# ---- Integrity ------------------------------------------------------------
# Everything fetched here is later EXECUTED, so nothing goes into bin\ until its
# SHA-256 matches the digest its publisher lists. A mismatch is fatal and the
# download is discarded rather than kept. Each project publishes the digest in a
# different shape, hence the three small readers below.
#
# Scope, so nobody reads more into this than it gives: each digest comes from the
# same origin and the same "latest" pointer as the file it covers, so it catches a
# corrupted or truncated transfer and a release landing mid-run - NOT a compromised
# publisher, who would simply serve a matching digest. Pin literal digests here if
# you need to defend against that.

function Get-RemoteText([string]$url) {
  $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 120
  if ($r.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($r.Content) }
  return [string]$r.Content
}

function Assert-Sha256([string]$file, [string]$expected, [string]$what) {
  if ([string]::IsNullOrWhiteSpace($expected)) {
    throw "$what : no published SHA-256 to verify against; refusing to install an unchecked binary."
  }
  $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
  if ($actual -ne $expected.Trim().ToUpperInvariant()) {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    throw "$what : SHA-256 mismatch. published $expected, got $actual. Download discarded."
  }
  Write-Host ('  verified SHA-256 ' + $actual.Substring(0, 16) + '...')
}

# yt-dlp: one "<hex>  <asset>" line per release asset.
function Get-YtDlpHash {
  $sums = Get-RemoteText 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS'
  foreach ($line in ($sums -split "`n")) {
    if ($line -match '^([0-9a-fA-F]{64})\s+yt-dlp\.exe\s*$') { return $Matches[1] }
  }
  return ''
}

# gyan.dev: a sidecar holding the bare hex digest.
function Get-FfmpegHash {
  return ((Get-RemoteText 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip.sha256').Trim() -split '\s+')[0]
}

# deno: a sidecar in PowerShell Get-FileHash layout ("Hash : <hex>").
function Get-DenoHash([string]$url) {
  $t = Get-RemoteText $url
  if ($t -match '(?im)^\s*Hash\s*:\s*([0-9a-fA-F]{64})\s*$') { return $Matches[1] }
  return ''  # only the structured line counts; any 64-hex run in the body does not
}

# ---- Downloads ------------------------------------------------------------
# NOTE: the binary and its digest are two separate requests against "latest". If a
# new release lands between them the check fails; just re-run.

Write-Host 'Downloading yt-dlp.exe...'
# Staged through a temp file: verification deletes what it rejects, and writing
# straight to bin\ would mean a mid-run release (see the note above) wipes a
# perfectly good yt-dlp.exe and leaves the host with nothing to run.
$ytExe = Join-Path $bin 'yt-dlp.exe'
$ytTmp = Join-Path $env:TEMP ('ytdlp_' + [System.Guid]::NewGuid().ToString('N') + '.exe')
$ytWant = Get-YtDlpHash
Invoke-WebRequest -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' `
  -OutFile $ytTmp -TimeoutSec 300
Assert-Sha256 $ytTmp $ytWant 'yt-dlp.exe'
Move-Item -LiteralPath $ytTmp -Destination $ytExe -Force

if (-not (Test-Path (Join-Path $bin 'ffmpeg.exe'))) {
  Write-Host 'Downloading ffmpeg (static, ~100MB)...'
  $tmp = Join-Path $env:TEMP ('ffdl_' + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'ffmpeg.zip'
  $ffWant = Get-FfmpegHash
  Invoke-WebRequest -Uri 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' `
    -OutFile $zip -TimeoutSec 580
  Assert-Sha256 $zip $ffWant 'ffmpeg-release-essentials.zip'
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $ff = Get-ChildItem -Path $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
  Copy-Item $ff.FullName -Destination (Join-Path $bin 'ffmpeg.exe') -Force
  Remove-Item -Recurse -Force $tmp
}

if (-not (Test-Path (Join-Path $bin 'deno.exe'))) {
  # yt-dlp needs a JavaScript runtime to run some sites' player JS; without one
  # those downloads fall back to formats that 403. deno is the runtime yt-dlp
  # supports out of the box (~95MB).
  Write-Host 'Downloading deno (JS runtime, ~40MB zip)...'
  $tmp = Join-Path $env:TEMP ('denodl_' + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'deno.zip'
  $denoUrl = 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip'
  $dnWant = Get-DenoHash ($denoUrl + '.sha256sum')
  Invoke-WebRequest -Uri $denoUrl -OutFile $zip -TimeoutSec 580
  Assert-Sha256 $zip $dnWant 'deno-x86_64-pc-windows-msvc.zip'
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $dn = Get-ChildItem -Path $tmp -Recurse -Filter deno.exe | Select-Object -First 1
  Copy-Item $dn.FullName -Destination (Join-Path $bin 'deno.exe') -Force
  Remove-Item -Recurse -Force $tmp
}

Get-ChildItem $bin | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
Write-Host 'Binaries ready in bin\.'
