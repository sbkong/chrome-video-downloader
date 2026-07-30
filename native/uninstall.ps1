# Removes the yt-dlp native messaging host registration created by install.ps1.
#   .\uninstall.ps1

$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostName = 'com.sbk.ytdlp'

$chromeKey = 'HKCU\Software\Google\Chrome\NativeMessagingHosts\' + $hostName
$edgeKey   = 'HKCU\Software\Microsoft\Edge\NativeMessagingHosts\' + $hostName
foreach ($key in @($chromeKey, $edgeKey)) {
  & reg.exe delete $key /f 2>$null | Out-Null
  Write-Host "Removed $key"
}

Remove-Item -Path (Join-Path $here 'run_host.bat') -Force
Remove-Item -Path (Join-Path $here ($hostName + '.json')) -Force
Write-Host 'Uninstalled. (yt-dlp itself was left installed.)'
