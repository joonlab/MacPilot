# MacPilot — 로그인 시 자동 시작 (시작프로그램 바로가기) (초안 / DRAFT)
#
# ⚠️ helper는 이 작업을 자동으로 하지 않습니다. 내용을 검토 후 직접 실행하세요.
#    관리자 권한이 필요 없는, 현재 사용자 Startup 폴더 바로가기 방식입니다.
#    (Windows Service 등록이 아니라 MVP에 적합한 사용자 시작프로그램입니다.)
#
# 사용:  .\scripts\startup-install.ps1 -ExePath "D:\path\to\MacPilot.Windows.exe" [-Args "--port 8765"]

param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [string]$Args = ""
)
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ExePath)) { Write-Error "실행 파일을 찾을 수 없습니다: $ExePath"; exit 1 }

$startup = [Environment]::GetFolderPath("Startup")   # %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
$lnkPath = Join-Path $startup "MacPilot Helper.lnk"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath = $ExePath
if ($Args) { $shortcut.Arguments = $Args }
$shortcut.WorkingDirectory = (Split-Path $ExePath -Parent)
$shortcut.Description = "MacPilot Windows Helper"
$shortcut.Save()

Write-Host "시작프로그램 바로가기 생성됨: $lnkPath"
Write-Host "제거: .\scripts\startup-remove.ps1"
