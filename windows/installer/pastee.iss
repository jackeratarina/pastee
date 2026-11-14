; Inno Setup script for the Pastee Windows installer.
; Built by .github/workflows/build.yml:
;   iscc /DAppVersion=1.1.0 windows\installer\pastee.iss
; Paths are relative to this file.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
; Never change AppId: Windows uses it to recognize upgrades of the same app.
AppId={{4A7218F1-5DCB-4D3B-B5EB-ADEE6B99FBA8}
AppName=Pastee
AppVersion={#AppVersion}
AppVerName=Pastee {#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher=Pastee
AppPublisherURL=https://github.com/jackeratarina/pastee
AppSupportURL=https://github.com/jackeratarina/pastee/issues
AppUpdatesURL=https://github.com/jackeratarina/pastee/releases
DefaultDirName={autopf}\Pastee
DefaultGroupName=Pastee
DisableProgramGroupPage=yes
; Installs for the current user without asking for admin rights.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\..\dist
OutputBaseFilename=Pastee-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\pastee.exe
UninstallDisplayName=Pastee
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Close a running Pastee before upgrading it.
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "startup"; Description: "Start Pastee when I sign in, so the summon shortcut is always ready"; GroupDescription: "Startup:"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Pastee"; Filename: "{app}\pastee.exe"
Name: "{autodesktop}\Pastee"; Filename: "{app}\pastee.exe"; Tasks: desktopicon
; Starts minimized: Pastee waits on the taskbar for the summon shortcut.
Name: "{autostartup}\Pastee"; Filename: "{app}\pastee.exe"; Tasks: startup; Flags: runminimized

[Run]
Filename: "{app}\pastee.exe"; Description: "{cm:LaunchProgram,Pastee}"; Flags: nowait postinstall skipifsilent
