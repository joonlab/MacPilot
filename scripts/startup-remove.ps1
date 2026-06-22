# MacPilot — 시작프로그램 바로가기 제거 (초안 / DRAFT)
$ErrorActionPreference = "Stop"
$lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "MacPilot Helper.lnk"
if (Test-Path $lnk) { Remove-Item $lnk; Write-Host "제거됨: $lnk" } else { Write-Host "바로가기가 없습니다: $lnk" }
