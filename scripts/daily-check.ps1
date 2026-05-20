<#
.SYNOPSIS
  SessionStart 自动跑的轻量 doctor。只查 5 个高频死亡点，<3s 完成。

.DESCRIPTION
  - server health (skip if Quick)
  - listener 活否
  - AHK 活否
  - slot 表死 PID
  - 近期 inject 活动
  PASS 静默退出 0；FAIL 时 stdout 简短摘要让 Claude 看到。

  Cooldown: 5 分钟内只跑 1 次（防多 cc 窗口同时 SessionStart 重复跑）。
  --Force 跳过 cooldown。
#>
[CmdletBinding()]
param([switch]$Quick, [switch]$Force)

$CooldownFile = "$env:USERPROFILE\.claude\hooks\ntfy-doctor-last-run.txt"
$CooldownSec = 300

if (-not $Force -and (Test-Path $CooldownFile)) {
  try {
    $lastRun = [int64](Get-Content $CooldownFile -Raw -ErrorAction Stop).Trim()
    $now = [int64](Get-Date -UFormat %s)
    if (($now - $lastRun) -lt $CooldownSec) {
      exit 0  # 静默跳过
    }
  } catch {}
}

# 写新时间戳
try {
  Set-Content -Path $CooldownFile -Value ([int64](Get-Date -UFormat %s)) -Encoding ASCII -ErrorAction SilentlyContinue
} catch {}

$result = & "$PSScriptRoot\doctor.ps1" -Json -Quick:$Quick -Section all | ConvertFrom-Json
$failed = $result.checks | Where-Object Status -eq 'FAIL'

if ($failed.Count -eq 0) {
  exit 0   # 静默
} else {
  Write-Host ""
  Write-Host "[gen-ntfy daily-check] ntfy 链路有 $($failed.Count) 项 FAIL：" -ForegroundColor Red
  foreach ($f in $failed) {
    Write-Host "  - $($f.Id) $($f.Title): $($f.Detail)"
  }
  Write-Host ""
  Write-Host "  跑 /gen-ntfy fix 修复 或 /gen-ntfy doctor 看全报告" -ForegroundColor Yellow
  Write-Host ""
  exit 1
}
