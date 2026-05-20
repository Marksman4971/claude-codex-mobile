<#
.SYNOPSIS
  重启 AHK injector（kill + 重新启动）

.DESCRIPTION
  最高频痛点修复：AHK 长跑后状态漂移（焦点抢占/SetForegroundWindow 内部状态烂）。
  重启即恢复。无害可重复跑。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$AhkExe = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$Script = "$env:USERPROFILE\.claude\hooks\ntfy-injector.ahk"

if (-not (Test-Path $AhkExe)) {
  Write-Host "[ERR] AutoHotkey64.exe 不在 $AhkExe" -ForegroundColor Red
  Write-Host "      装 AutoHotkey v2 或检查路径"
  exit 1
}
if (-not (Test-Path $Script)) {
  Write-Host "[ERR] ntfy-injector.ahk 不在 $Script" -ForegroundColor Red
  exit 1
}

# kill 现有 AHK
$existing = @(Get-Process AutoHotkey64 -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
  $existing | ForEach-Object {
    Write-Host "[KILL] AHK PID=$($_.Id) Uptime=$([int]((Get-Date) - $_.StartTime).TotalMinutes)min"
    Stop-Process -Id $_.Id -Force
  }
  Start-Sleep -Milliseconds 500
} else {
  Write-Host "[INFO] 无现有 AHK 进程"
}

# 启动
Start-Process $AhkExe -ArgumentList "`"$Script`""
Start-Sleep -Milliseconds 800

# 验证
$new = @(Get-Process AutoHotkey64 -ErrorAction SilentlyContinue)
if ($new.Count -ge 1) {
  $n = $new[0]
  Write-Host "[OK] AHK 重启完成 PID=$($n.Id) Responding=$($n.Responding)" -ForegroundColor Green
  exit 0
} else {
  Write-Host "[FAIL] AHK 启动后进程不存在" -ForegroundColor Red
  exit 1
}
