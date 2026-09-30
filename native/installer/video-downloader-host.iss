; Installer for the Video Downloader native messaging host.
;
; The extension cannot download video itself - a browser extension cannot run a
; local program. This installs the small PowerShell host that does, and registers
; it with Chrome and Edge so the extension is allowed to talk to it.
;
; Deliberate choices:
;   * Per-user install. The host registers under HKCU, so no administrator rights
;     and no UAC prompt are needed. Asking for elevation we do not need would be
;     both rude and a worse trust signal.
;   * The downloader binaries are NOT bundled. They are fetched during install
;     from each project's own official distribution (see fetch-binaries.ps1),
;     which keeps this file small and keeps one less party in the trust chain.
;   * Uninstall removes the registry keys, the fetched binaries and the logs.
;
; Build:  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" video-downloader-host.iss

#define AppName        "Video Downloader Host"
#define AppVersion     "1.0.0"
#define AppPublisher   "sbkong"
#define AppUrl         "https://github.com/sbkong/chrome-video-downloader"
#define HostName       "com.sbk.ytdlp"
#define NativeDir      ".."

[Setup]
AppId={{D780DFAE-21AF-4F4C-8CB5-5E8A47BFD162}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
DefaultDirName={localappdata}\VideoDownloaderHost
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=video-downloader-host-setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ko"; MessagesFile: "compiler:Languages\Korean.isl"

[Files]
Source: "{#NativeDir}\host.ps1";           DestDir: "{app}"; Flags: ignoreversion
Source: "{#NativeDir}\host.bat";           DestDir: "{app}"; Flags: ignoreversion
Source: "{#NativeDir}\fetch-binaries.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#NativeDir}\install.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "{#NativeDir}\uninstall.ps1";      DestDir: "{app}"; Flags: ignoreversion

; Chrome and Edge each look up native hosts under their own key. uninsdeletekey
; is what makes uninstalling actually unregister the host instead of leaving a
; dangling entry pointing at a deleted folder.
[Registry]
Root: HKCU; Subkey: "Software\Google\Chrome\NativeMessagingHosts\{#HostName}"; \
  ValueType: string; ValueName: ""; ValueData: "{app}\{#HostName}.json"; \
  Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Edge\NativeMessagingHosts\{#HostName}"; \
  ValueType: string; ValueName: ""; ValueData: "{app}\{#HostName}.json"; \
  Flags: uninsdeletekey

; install.ps1 writes the host manifest (with every allowed extension ID) and
; fetches the downloader binaries. The window stays visible on purpose: this step
; pulls a few hundred megabytes and a silent multi-minute pause looks like a hang.
[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"""; \
  WorkingDir: "{app}"; \
  StatusMsg: "{cm:FetchingMsg}"; \
  Flags: waituntilterminated

[UninstallDelete]
Type: filesandordirs; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\logs"
Type: files;          Name: "{app}\{#HostName}.json"

[CustomMessages]
en.FetchingMsg=Downloading yt-dlp, ffmpeg and deno from their official releases. This can take a few minutes.
ko.FetchingMsg=yt-dlp, ffmpeg, deno를 공식 배포처에서 내려받는 중입니다. 몇 분 걸릴 수 있습니다.
en.FinishedLabel=The downloader is installed. Open the extension and try a video - if its popup still says the host is missing, reload the extension once.
ko.FinishedLabel=다운로더가 설치되었습니다. 확장을 열고 영상에서 시도해 보세요. 팝업에 호스트가 없다고 나오면 확장을 한 번 새로고침하세요.
