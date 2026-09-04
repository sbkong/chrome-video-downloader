# Native messaging host (Windows PowerShell, no Python needed).
# Reads { "url", "savePath" } from the extension over stdin (4-byte LE length +
# UTF-8 JSON), runs the bundled yt-dlp.exe (+ ffmpeg.exe to merge, deno.exe as the
# JavaScript runtime some extractors need) to download, and streams
# progress/done/error back using the same framing.

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin   = Join-Path $root 'bin'
$ytdlp = Join-Path $bin 'yt-dlp.exe'
$logDir = Join-Path $root 'logs'
try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } } catch {}

# Media URLs routinely carry CDN auth in the query string (tokens, signatures,
# expiry windows). These logs are plain files that sit on disk, so scrub those
# values before anything is written. The rest of the URL is kept - that is what
# makes a log worth having - and ordinary identifiers (?v=, &list=) are untouched.
$SECRET_PARAM_RE = '(?i)((?:token|sig|signature|hmac|key|secret|auth|authorization|password|passwd|session|sid|cookie|policy|credential|expires?|access_token|id_token|refresh_token|Key-Pair-Id|X-Amz-[A-Za-z0-9-]+|__hdnea__)=)[^&\s"'']*'

function Redact([string]$m) {
  if ([string]::IsNullOrEmpty($m)) { return $m }
  return ($m -replace $SECRET_PARAM_RE, '$1<redacted>')
}

function Log([string]$m) {
  try {
    $file = Join-Path $logDir ((Get-Date -Format 'yyyy-MM-dd') + '.log')
    Add-Content -Path $file -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + (Redact $m)) -Encoding utf8
  } catch {}
}

# One log file per day with nothing pruning them is a permanent record of what the
# user watched and downloaded. Keep two weeks.
function Remove-OldLogs {
  try {
    $cutoff = (Get-Date).AddDays(-14)
    Get-ChildItem -Path $logDir -Filter '*.log' -File |
      Where-Object { $_.LastWriteTime -lt $cutoff } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
  } catch {}
}
Remove-OldLogs
Log '--- host started ---'

$stdin  = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()

function Read-Exact([int]$n) {
  $buf = New-Object byte[] $n
  $off = 0
  while ($off -lt $n) {
    $r = $stdin.Read($buf, $off, $n - $off)
    if ($r -le 0) { return $null }
    $off += $r
  }
  return ,$buf
}

function Read-Message {
  $l = Read-Exact 4
  if ($null -eq $l) { return $null }
  $len = [BitConverter]::ToInt32($l, 0)
  if ($len -le 0 -or $len -gt 67108864) { return $null }
  $d = Read-Exact $len
  if ($null -eq $d) { return $null }
  return ([System.Text.Encoding]::UTF8.GetString($d) | ConvertFrom-Json)
}

function Send-Message($obj) {
  $json  = $obj | ConvertTo-Json -Compress -Depth 6
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $stdout.Write([BitConverter]::GetBytes([int]$bytes.Length), 0, 4)
  $stdout.Write($bytes, 0, $bytes.Length)
  $stdout.Flush()
}

# Keep yt-dlp current without any user action: at most once per 24h, run its
# built-in self-update (-U). This is what handles sites changing / yt-dlp needing
# a newer version, while the bundle stays simple. ffmpeg rarely needs updating.
function Update-YtDlpIfStale {
  try {
    if (-not (Test-Path $ytdlp)) { return }
    $marker = Join-Path $bin '.last_update'
    if (Test-Path $marker) {
      $age = (Get-Date) - (Get-Item $marker).LastWriteTime
      if ($age.TotalHours -lt 24) { return }
    }
    Log 'yt-dlp: checking for update (-U)...'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $ytdlp -U 2>&1 | ForEach-Object { Log ('update> ' + [string]$_) } }
    finally { $ErrorActionPreference = $prev }
    Test-YtDlpHash
    Set-Content -Path $marker -Value (Get-Date -Format 'o') -Encoding ascii
  } catch { Log ('update check failed: ' + $_.Exception.Message) }
}

# Check the yt-dlp.exe on disk against the SHA-256 the project publishes for its
# latest release. yt-dlp's own updater verifies what it downloads before swapping
# it in; this is a second, independent look, so a bad binary shows up in the log
# instead of silently running. A mismatch only WARNS: it also happens innocently
# when a newer release exists but -U has not run yet, and network trouble must
# never block a download.
function Test-YtDlpHash {
  try {
    $r = Invoke-WebRequest -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS' `
           -UseBasicParsing -TimeoutSec 20
    $txt = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
    $want = ''
    foreach ($line in ($txt -split "`n")) {
      if ($line -match '^([0-9a-fA-F]{64})\s+yt-dlp\.exe\s*$') { $want = $Matches[1]; break }
    }
    if (-not $want) { Log 'update: no published hash for yt-dlp.exe; verification skipped'; return }
    $have = (Get-FileHash -LiteralPath $ytdlp -Algorithm SHA256).Hash
    if ($have -eq $want.ToUpperInvariant()) {
      Log ('update: yt-dlp.exe verified (' + $have.Substring(0, 16) + '...)')
    } else {
      Log ('WARNING: yt-dlp.exe does not match the published release hash (have ' +
           $have.Substring(0, 16) + '..., published ' + $want.Substring(0, 16) + '...)')
    }
  } catch { Log ('update: hash verification skipped (' + $_.Exception.Message + ')') }
}

# A plain, directly-fetchable media file (not an HLS/DASH manifest or a webpage).
function Test-DirectMedia([string]$url) {
  return ($url -match '\.(mp4|m4v|mov|mkv|webm|avi|flv|ts|mp3|m4a|aac|ogg|oga|wav|wmv)(\?|#|$)')
}

# Resolve the save folder for the plain-download fallback (yt-dlp normally handles
# this via -o/-P). Tokens: {domain} -> URL host, {title} -> file name (no ext).
function Resolve-DestFolder([string]$setting, [string]$url) {
  $base = Join-Path $env:USERPROFILE 'Downloads'
  if ([string]::IsNullOrWhiteSpace($setting)) { return $base }
  $vhost = 'site'; $title = 'video'
  try { $u = [Uri]$url; $vhost = $u.Host; $title = [System.IO.Path]::GetFileNameWithoutExtension($u.AbsolutePath) } catch {}
  $folder = $setting -replace '\{domain\}', $vhost -replace '\{title\}', $title
  if ([System.IO.Path]::IsPathRooted($folder)) { return $folder.TrimEnd('\', '/') }
  return (Join-Path $base (($folder -replace '/', '\').Trim('\')))
}

# Fallback download: fetch a direct media URL over HTTP (with Referer for hotlink
# protection), used only when yt-dlp itself couldn't get the file.
function Invoke-DirectDownload([string]$url, [string]$folder, [string]$referer) {
  if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
  $name = ''
  try { $name = [System.IO.Path]::GetFileName(([Uri]$url).AbsolutePath) } catch {}
  if ([string]::IsNullOrWhiteSpace($name)) { $name = 'video.mp4' }
  $dest = Join-Path $folder $name
  $headers = @{}
  if ($referer) { $headers['Referer'] = $referer }
  $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try { Invoke-WebRequest -Uri $url -OutFile $dest -Headers $headers -UserAgent 'Mozilla/5.0' -UseBasicParsing }
  finally { $ProgressPreference = $old }
  return $dest
}

function Invoke-Download($msg) {
  if (-not $msg.url) { Send-Message @{ type = 'error'; message = 'no url' }; return }
  if (-not (Test-Path $ytdlp)) { Send-Message @{ type = 'error'; message = 'yt-dlp.exe missing in bin/' }; return }

  Update-YtDlpIfStale

  # Build the output path. The "save folder" setting may contain {domain} and
  # {title} tokens, which map to yt-dlp output fields (so folders use yt-dlp's own
  # accurate metadata). Absolute path -> used as-is; relative -> under Downloads.
  $fileTmpl = '%(title).150B [%(id)s].%(ext)s'
  $dlBase   = Join-Path $env:USERPROFILE 'Downloads'
  $setting  = if ($msg.savePath) { ([string]$msg.savePath).Trim() } else { '' }

  $ytArgs = @('--newline', '--no-playlist')
  if (Test-Path (Join-Path $bin 'ffmpeg.exe')) { $ytArgs += @('--ffmpeg-location', $bin) }

  # Some sites hand out format URLs carrying a parameter that only the site's own
  # JavaScript can compute. yt-dlp needs a JavaScript runtime for that; it only
  # auto-detects deno on PATH, so point it at the bundled copy. Without it yt-dlp
  # silently drops those formats and falls back to ones that fail with HTTP 403.
  $deno = Join-Path $bin 'deno.exe'
  if (Test-Path $deno) { $ytArgs += @('--js-runtimes', ('deno:' + $deno)) }
  else { Log 'WARNING: bin\deno.exe missing - some sites will likely fail with HTTP 403 (run fetch-binaries.ps1)' }

  # Pin the embedded player client where yt-dlp's default choice now returns
  # formats with no direct URL (or token-gated ones) that end up 403ing; the
  # embedded client still serves plain HTTPS formats once the JS challenge above is
  # solved. "default" stays as a fallback so other clients can fill in when it has
  # nothing. The arg is ignored on sites it does not apply to.
  $ytArgs += @('--extractor-args', 'youtube:player_client=web_embedded,default')
  if ($msg.referer) { $ytArgs += @('--referer', [string]$msg.referer) }

  # Optionally use the logged-in Chrome session's cookies so videos a site only
  # serves to a signed-in account download with the user's own access. NOTE this
  # hands yt-dlp the ENTIRE Chrome cookie store, not just the target site's - the
  # flag has no per-domain form. Off by default, both for that reason and because
  # reading Chrome's cookie DB can fail (locked / app-bound encryption) and would
  # then abort even ordinary downloads. Toggled in the popup.
  if ($msg.cookies) { $ytArgs += @('--cookies-from-browser', 'chrome') }

  # Prefer H.264 mp4 video + AAC (m4a) stereo audio, merged into mp4. The usual
  # "best" is VP9/webm + Opus audio, which is what makes files come out as
  # .webm and can play with broken / single-channel sound in many players. The
  # fallback chain still lets any single-file source (a plain .mp4, HLS/DASH, etc.)
  # download. --merge-output-format mp4 + --remux ensures the container is mp4.
  $ytArgs += @('-f', 'bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b',
               '--merge-output-format', 'mp4',
               '--remux-video', 'mp4')

  if ([string]::IsNullOrWhiteSpace($setting)) {
    $ytArgs += @('-P', $dlBase, '-o', $fileTmpl)
  } else {
    $folder = $setting -replace '\{domain\}', '%(webpage_url_domain)s' -replace '\{title\}', '%(title)s'
    if ([System.IO.Path]::IsPathRooted($folder)) {
      $ytArgs += @('-o', ($folder.TrimEnd('\', '/') + '\' + $fileTmpl))
    } else {
      $rel = ($folder -replace '\\', '/').Trim('/')
      $ytArgs += @('-P', $dlBase, '-o', ($rel + '/' + $fileTmpl))
    }
  }
  $ytArgs += [string]$msg.url

  Log ('URL=' + [string]$msg.url)
  Log ('savePath=' + $setting)
  Log ('CMD: "' + $ytdlp + '" ' + ($ytArgs -join ' '))

  $last = $null
  $tail = New-Object System.Collections.Generic.List[string]

  # One download runs through SEVERAL yt-dlp stages: with -f bv*+ba it fetches the
  # video stream 0-100%, then the audio stream 0-100%, then merges. Forwarding each
  # stage's own percent makes the UI count up twice, so give every stage its own
  # slice of a single 0-100 range (video streams are far bigger than audio, hence
  # the lopsided weights) and never let the reported value go backwards.
  $partWeights = @(1.0)
  $partIndex   = 0
  $partsSeen   = 0
  $maxPct      = 0.0
  # IMPORTANT: yt-dlp prints warnings to stderr. With 2>&1 under
  # $ErrorActionPreference='Stop', PowerShell promotes any stderr line to a
  # terminating error and aborts a download that yt-dlp would have finished. Use
  # 'Continue' here and rely on the exit code alone to judge success/failure.
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $ytdlp @ytArgs 2>&1 | ForEach-Object {
      $line = [string]$_
      if ($line.Length -gt 500) { $line = $line.Substring(0, 500) }
      Log ('yt-dlp> ' + $line)
      $tail.Add($line); if ($tail.Count -gt 8) { $tail.RemoveAt(0) }
      if ($line -match 'Destination:\s*(.+)$') {
        $last = $Matches[1]
        $partsSeen++
        $partIndex = [Math]::Min($partsSeen - 1, $partWeights.Count - 1)  # next stage started
      }
      elseif ($line -match 'Merging formats into "(.+)"') { $last = $Matches[1] }
      elseif ($line -match '\[download\]\s*(.+?)\s+has already been downloaded') { $last = $Matches[1] }
      elseif ($line -match 'Downloading \d+ format\(s\):\s*(\S+)') {
        # e.g. "Downloading 1 format(s): 137+140" -> two streams to fetch in turn.
        $n = ([string]$Matches[1]).Split('+').Count
        if ($n -eq 2) { $partWeights = @(0.88, 0.12) }
        elseif ($n -gt 2) { $partWeights = @(1..$n | ForEach-Object { 1.0 / $n }) }
        else { $partWeights = @(1.0) }
      }
      # Only real progress lines ("[download]  12.3% of ...") carry a percent.
      # Matching bare "%" anywhere picked up unrelated output too.
      $pct = $null
      if ($line -match '^\[download\]\s+(\d{1,3}(?:\.\d+)?)%') {
        $raw  = [double]$Matches[1]
        $base = 0.0
        for ($i = 0; $i -lt $partIndex; $i++) { $base += $partWeights[$i] }
        $w = $partWeights[[Math]::Min($partIndex, $partWeights.Count - 1)]
        $pct = [Math]::Round(($base + $w * $raw / 100.0) * 100.0, 1)
        if ($pct -lt $maxPct) { $pct = $maxPct } else { $maxPct = $pct }
      }
      Send-Message @{ type = 'progress'; line = $line; percent = $pct }
    }
  } finally {
    $ErrorActionPreference = $prevEAP
  }

  $code = $LASTEXITCODE
  Log ('exit code=' + $code)
  if ($code -eq 0) {
    $name = if ($last) { Split-Path -Leaf $last } else { $null }
    Log ('DONE file=' + $name)
    Send-Message @{ type = 'done'; ok = $true; file = $name; path = $last }
  } else {
    Log ('yt-dlp failed (code ' + $code + ')')
    # Fallback: if the URL is a plain media file, yt-dlp's generic extractor may
    # have choked where a direct HTTP GET works. Try that before giving up.
    if (Test-DirectMedia ([string]$msg.url)) {
      Log 'attempting direct HTTP fallback...'
      Send-Message @{ type = 'progress'; line = 'yt-dlp failed; trying direct download...'; percent = $null }
      try {
        $folder = Resolve-DestFolder $setting ([string]$msg.url)
        $dest   = Invoke-DirectDownload ([string]$msg.url) $folder ([string]$msg.referer)
        Log ('DIRECT DONE file=' + (Split-Path -Leaf $dest))
        Send-Message @{ type = 'done'; ok = $true; file = (Split-Path -Leaf $dest); path = $dest }
        return
      } catch {
        Log ('direct fallback failed: ' + $_.Exception.Message)
      }
    }
    Log 'ERROR reported to extension'
    Send-Message @{ type = 'error'; message = ("yt-dlp exited with code " + $code + "`n" + ($tail -join "`n")) }
  }
}

# Open Explorer on a finished download. Defence in depth: the extension already
# refuses paths it did not record, but explorer.exe LAUNCHES any executable path
# handed to it, so re-check here. -LiteralPath stops wildcard matches, a quote
# would break out of the argument we build, and the fallback must land on a real
# directory (a parent that is itself a file would get executed).
function Reveal-Path([string]$path) {
  try {
    if ([string]::IsNullOrWhiteSpace($path) -or $path.Contains('"')) {
      Log ('reveal refused (invalid path)')
      Send-Message @{ type = 'revealed'; ok = $false; message = 'invalid path' }
      return
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      Start-Process explorer.exe -ArgumentList ('/select,"' + $path + '"')
    } else {
      $dir = Split-Path -Parent $path
      if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
        Start-Process explorer.exe -ArgumentList ('"' + $dir + '"')
      }
    }
    Send-Message @{ type = 'revealed'; ok = $true }
  } catch { Send-Message @{ type = 'revealed'; ok = $false; message = $_.Exception.Message } }
}

while ($true) {
  $msg = Read-Message
  if ($null -eq $msg) { Log 'stdin closed; exiting'; break }
  Log ('message received: ' + ($msg | ConvertTo-Json -Compress))
  if ($msg.cmd -eq 'reveal') { Reveal-Path ([string]$msg.path); continue }
  if ($msg.cmd -eq 'exists') {
    # Report which of the given paths no longer exist, so the extension can drop
    # stale "done" entries for files the user has since deleted.
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($msg.paths)) {
      if ($p -and -not (Test-Path -LiteralPath ([string]$p))) { $missing.Add([string]$p) }
    }
    Send-Message @{ type = 'exists'; missing = @($missing) }
    continue
  }
  try { Invoke-Download $msg }
  catch { Log ('EXCEPTION: ' + $_.Exception.Message); Send-Message @{ type = 'error'; message = $_.Exception.Message } }
}
