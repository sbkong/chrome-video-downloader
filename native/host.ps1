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
  Log ('savePath=' + $save)
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
    Send-Message @{ type = 'done'; ok = $true; file = $name }
  } else {
    Log 'ERROR reported to extension'
    Send-Message @{ type = 'error'; message = ("yt-dlp exited with code " + $code + "`n" + ($tail -join "`n")) }
  }
}

while ($true) {
  $msg = Read-Message
  if ($null -eq $msg) { Log 'stdin closed; exiting'; break }
  Log ('message received: ' + ($msg | ConvertTo-Json -Compress))
  try { Invoke-Download $msg }
  catch { Log ('EXCEPTION: ' + $_.Exception.Message); Send-Message @{ type = 'error'; message = $_.Exception.Message } }
}
