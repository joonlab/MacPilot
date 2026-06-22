# MacPilot — 방화벽 규칙 제거 (초안 / DRAFT). 관리자 권한 PowerShell 에서 직접 실행.
param([int]$Port = 8765)
$ErrorActionPreference = "Stop"
$name = "MacPilot (TCP $Port, Private)"
if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -DisplayName $name
    Write-Host "방화벽 규칙 제거됨: $name"
} else {
    Write-Host "규칙이 없습니다: $name"
}
