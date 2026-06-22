# MacPilot — Windows Defender 방화벽 인바운드 허용 (초안 / DRAFT)
#
# ⚠️ 이 스크립트는 helper가 자동 실행하지 않습니다. 내용을 검토하고, 본인 환경에서
#    관리자 권한 PowerShell로 직접 실행하세요. 사설망(Private) 프로필에만 허용합니다.
#
# 사용:  관리자 PowerShell 에서  ->  .\scripts\firewall-allow.ps1 [-Port 8765]

param([int]$Port = 8765)

$ErrorActionPreference = "Stop"

# 관리자 권한 확인
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "관리자 권한이 필요합니다. PowerShell을 '관리자 권한으로 실행' 후 다시 시도하세요."
    exit 1
}

$name = "MacPilot (TCP $Port, Private)"
if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) {
    Write-Host "이미 규칙이 존재합니다: $name"
    exit 0
}

New-NetFirewallRule -DisplayName $name `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Private | Out-Null
Write-Host "방화벽 규칙 추가됨: $name"
Write-Host "되돌리기: .\scripts\firewall-remove.ps1 -Port $Port"
