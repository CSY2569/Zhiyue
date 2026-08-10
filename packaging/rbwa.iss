; Inno Setup 安装脚本 —— 智阅（Windows x64）
; 用法：安装 Inno Setup（https://jrsoftware.org/isinfo.php），
;       在 packaging\ 目录下编译本文件（右键 → Compile）。
; 产物：dist\rbwa-<version>-win-x64-setup.exe
;
; 前置：先完成 docs\WINDOWS_BUILD.md 的构建步骤（flutter build windows --release）。

[Setup]
AppName=智阅
AppVersion=0.1.0
AppPublisher=RBWA
AppPublisherURL=https://localhost/rbwa
DefaultDirName={autopf}\RBWA
DefaultGroupName=智阅
OutputDir=..\dist
OutputBaseFilename=rbwa-0.1.0-win-x64-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
SetupLogging=yes
UninstallDisplayName=智阅
UninstallDisplayIcon={app}\rbwa.exe

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\智阅"; Filename: "{app}\rbwa.exe"
Name: "{autodesktop}\智阅"; Filename: "{app}\rbwa.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标："

[Run]
Filename: "{app}\rbwa.exe"; Description: "立即运行智阅"; Flags: nowait postinstall skipifsilent
