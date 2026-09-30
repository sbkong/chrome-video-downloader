# Downloads the bundled binaries into bin\: yt-dlp.exe (the downloader), static
# ffmpeg.exe (merges separate audio/video streams) and deno.exe (the JavaScript
# runtime yt-dlp needs on some sites).
# For maintainers: run once to (re)build the bundle or to update yt-dlp.
#   .\fetch-binaries.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin = Join-Path $here 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null

# ---- Version policy -------------------------------------------------------
# The three binaries are not alike, because of WHO calls them.
#
# yt-dlp is called by this project directly, and it has to keep up with the sites
# it downloads from - a months-old copy simply stops working. So it follows the
# latest release, and host.ps1 keeps it current afterwards with -U. The cost is
# that its hash cannot be pinned here: a moving target has no fixed hash, so it is
# checked against the digest its own release publishes.
#
# ffmpeg and deno are never called by us - yt-dlp invokes them, with arguments we
# never see. Nothing about them needs to be new, and a new major version is a way
# for downloads that work today to break tomorrow. So both are pinned to the exact
# build this project has been tested against, and verified against a digest
# committed HERE rather than one fetched from the download site. That is the
# stronger check: a compromised or spoofed site can serve a matching sidecar
# digest, but it cannot match a hash that already sits in git.
#
# To move a pin: change the version and URL, delete the old .exe from bin\, run
# this, and paste the SHA-256 it prints for the extracted executable.
$FFMPEG_VERSION = '8.1.2'
$FFMPEG_URL     = 'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-8.1.2-essentials_build.zip'
$FFMPEG_EXE_SHA = '1326DDE4C84FF1F96FE6B8916C5BED29E163E9B5DCCF995F6F3DB069D143EC5E'

$DENO_VERSION   = '2.9.5'
$DENO_URL       = 'https://github.com/denoland/deno/releases/download/v2.9.5/deno-x86_64-pc-windows-msvc.zip'
$DENO_EXE_SHA   = '98F8C2A2D470E4CCB04C935C86FF8050817D877762AEC5EAEEB9E409CCB3B9FD'

$YTDLP_URL      = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
$YTDLP_SUMS_URL = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS'

# ---- Integrity helpers ----------------------------------------------------

function Get-RemoteText([string]$url) {
  $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 120
  if ($r.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($r.Content) }
  return [string]$r.Content
}

function Assert-Sha256([string]$file, [string]$expected, [string]$what) {
  if ([string]::IsNullOrWhiteSpace($expected)) {
    throw "$what : no SHA-256 to verify against; refusing to install an unchecked binary."
  }
  $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
  if ($actual -ne $expected.Trim().ToUpperInvariant()) {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    throw "$what : SHA-256 mismatch. expected $expected, got $actual. Download discarded."
  }
  Write-Host ('  verified SHA-256 ' + $actual.Substring(0, 16) + '...')
}

# Fetch a pinned archive, unpack it, and install the executable only once it
# matches the hash committed in this file.
function Install-PinnedExe([string]$url, [string]$sidecarUrl, [string]$exeName, [string]$pinnedSha, [string]$label) {
  $tmp = Join-Path $env:TEMP ('vdlfetch_' + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    Write-Host ("Downloading $label...")
    $zip = Join-Path $tmp 'pkg.zip'

    # The publisher's own digest first - it catches a truncated transfer before we
    # spend time unpacking 100MB. It is not the real gate, so a missing sidecar is
    # not fatal.
    $zipWant = ''
    try {
      $sidecar = Get-RemoteText $sidecarUrl
      if ($sidecar -match '(?im)^\s*Hash\s*:\s*([0-9a-fA-F]{64})\s*$') { $zipWant = $Matches[1] }
      elseif ($sidecar -match '([0-9a-fA-F]{64})') { $zipWant = $Matches[1] }
    } catch { Write-Host '  (publisher digest unavailable; the pinned hash below still applies)' }

    # Everything is fetched from the project's own official distribution, never a
    # mirror of ours - one less party to trust, and the pinned hash below already
    # covers tampering. The price is that a publisher may retire an old build, so
    # say plainly what to do when the pinned URL stops resolving. Never silently
    # fall back to "latest": that would quietly undo the pin.
    try {
      Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 580
    } catch {
      throw ("$label : could not download the pinned build from $url`n" +
             "  The publisher may have retired it. Pick a current version, update the " +
             "matching `$..._VERSION / `$..._URL / `$..._EXE_SHA in this file, and re-run.`n" +
             "  Underlying error: " + $_.Exception.Message)
    }
    if ($zipWant) { Assert-Sha256 $zip $zipWant ($label + ' archive') }

    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $found = Get-ChildItem -LiteralPath $tmp -Recurse -Filter $exeName | Select-Object -First 1
    if (-not $found) { throw "$label : $exeName was not found inside the archive." }

    # The gate that matters: this hash lives in git, not on the download server.
    Assert-Sha256 $found.FullName $pinnedSha $label
    Copy-Item -LiteralPath $found.FullName -Destination (Join-Path $bin $exeName) -Force
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# ---- yt-dlp: always the latest release -------------------------------------
# One "<hex>  <asset>" line per release asset.
function Get-YtDlpHash {
  foreach ($line in ((Get-RemoteText $YTDLP_SUMS_URL) -split "`n")) {
    if ($line -match '^([0-9a-fA-F]{64})\s+yt-dlp\.exe\s*$') { return $Matches[1] }
  }
  return ''
}

Write-Host 'Downloading yt-dlp.exe (latest)...'
# Staged through a temp file: verification deletes what it rejects, and writing
# straight to bin\ would mean a release landing mid-run wipes a working copy and
# leaves the host with nothing to run.
$ytExe = Join-Path $bin 'yt-dlp.exe'
$ytTmp = Join-Path $env:TEMP ('ytdlp_' + [System.Guid]::NewGuid().ToString('N') + '.exe')
$ytWant = Get-YtDlpHash
Invoke-WebRequest -Uri $YTDLP_URL -OutFile $ytTmp -TimeoutSec 300
Assert-Sha256 $ytTmp $ytWant 'yt-dlp.exe'
Move-Item -LiteralPath $ytTmp -Destination $ytExe -Force

# ---- ffmpeg and deno: pinned ----------------------------------------------
if (-not (Test-Path -LiteralPath (Join-Path $bin 'ffmpeg.exe'))) {
  Install-PinnedExe $FFMPEG_URL ($FFMPEG_URL + '.sha256') 'ffmpeg.exe' $FFMPEG_EXE_SHA "ffmpeg $FFMPEG_VERSION (~100MB)"
}
if (-not (Test-Path -LiteralPath (Join-Path $bin 'deno.exe'))) {
  Install-PinnedExe $DENO_URL ($DENO_URL + '.sha256sum') 'deno.exe' $DENO_EXE_SHA "deno $DENO_VERSION (~40MB zip)"
}

Get-ChildItem $bin | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
Write-Host ''
Write-Host "Pinned: ffmpeg $FFMPEG_VERSION, deno $DENO_VERSION. yt-dlp tracks latest and self-updates."
Write-Host 'Binaries ready in bin\.'
