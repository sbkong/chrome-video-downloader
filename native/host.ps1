# Native messaging host (Windows PowerShell, no Python needed).
# Reads { "url", "savePath" } from the extension over stdin (4-byte LE length +
# UTF-8 JSON), runs the bundled yt-dlp.exe (+ ffmpeg.exe) to download, and streams
# progress/done/error back using the same framing.

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin   = Join-Path $root 'bin'
$ytdlp = Join-Path $bin 'yt-dlp.exe'
$logDir = Join-Path $root 'logs'
try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } } catch {}

function Log([string]$m) {
  try {
    $file = Join-Path $logDir ((Get-Date -Format 'yyyy-MM-dd') + '.log')
    Add-Content -Path $file -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding utf8
  } catch {}
}
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
    Set-Content -Path $marker -Value (Get-Date -Format 'o') -Encoding ascii
  } catch { Log ('update check failed: ' + $_.Exception.Message) }
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
  if ($msg.referer) { $ytArgs += @('--referer', [string]$msg.referer) }

  # Optionally use the logged-in Chrome session's cookies so member-only /
  # purchased videos (Vimeo on-demand, etc.) download with the user's access.
  # Off by default because reading Chrome's cookie DB can fail (locked / app-bound
  # encryption) and would then abort even ordinary downloads. Toggled in the popup.
  if ($msg.cookies) { $ytArgs += @('--cookies-from-browser', 'chrome') }

  # Prefer H.264 mp4 video + AAC (m4a) stereo audio, merged into mp4. YouTube's
  # default "best" is VP9/webm + Opus audio, which is what makes files come out as
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
      if ($line -match 'Destination:\s*(.+)$') { $last = $Matches[1] }
      elseif ($line -match 'Merging formats into "(.+)"') { $last = $Matches[1] }
      elseif ($line -match '\[download\]\s*(.+?)\s+has already been downloaded') { $last = $Matches[1] }
      $pct = $null
      if ($line -match '(\d{1,3}(?:\.\d+)?)%') { $pct = [double]$Matches[1] }
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

function Reveal-Path([string]$path) {
  try {
    if ($path -and (Test-Path $path)) {
      Start-Process explorer.exe -ArgumentList ('/select,"' + $path + '"')
    } elseif ($path) {
      $dir = Split-Path -Parent $path
      if ($dir -and (Test-Path $dir)) { Start-Process explorer.exe -ArgumentList ('"' + $dir + '"') }
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
