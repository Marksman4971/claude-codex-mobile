<#
.SYNOPSIS
  gen-ntfy fix: 按 doctor FAIL 项精准修复

.DESCRIPTION
  默认逐项询问确认。--Auto 跳过确认一键修。
  修复顺序按 known-issues.md "修复优先级"：N1 server → N4 slot → N2/N3 进程 → N5 配置

.PARAMETER Auto
  跳过逐项确认，一键全修

.PARAMETER Section
  只修某一类 FAIL（N1/N2/N3/N4/N5）

.STATUS
  Phase 1: 仅实现高频修复（N3-1/3-2/3-3 重启 AHK、N4-1 清死 slot）
  Phase 2 TODO: N2-x listener 重启、N5-x hook 修复
#>
[CmdletBinding()]
param(
  [switch]$Auto,
  [ValidateSet('all','N1','N2','N3','N4','N5')]
  [string]$Section = 'all'
)

$ErrorActionPreference = 'Continue'
$ScriptsDir = $PSScriptRoot

function Confirm-Action {
  param([string]$Action)
  if ($Auto) { return $true }
  $resp = Read-Host "执行: $Action ? [Y/n]"
  return ($resp -eq '' -or $resp -match '^[Yy]')
}

Write-Host ""
Write-Host "===== gen-ntfy fix =====" -ForegroundColor Cyan
Write-Host "策略: 先跑 doctor 拿 FAIL 项，再按优先级逐项修" -ForegroundColor Gray
Write-Host ""

# 1. 跑 doctor --json 拿结构化报告
$doctorJson = & "$ScriptsDir\doctor.ps1" -Json | ConvertFrom-Json
$failed = $doctorJson.checks | Where-Object Status -eq 'FAIL'
$warned = $doctorJson.checks | Where-Object Status -eq 'WARN'

if ($failed.Count -eq 0 -and $warned.Count -eq 0) {
  Write-Host "[OK] doctor 全 PASS，无需修复" -ForegroundColor Green
  exit 0
}

Write-Host "FAIL: $($failed.Count) 项 / WARN: $($warned.Count) 项" -ForegroundColor Yellow
Write-Host ""

# 2. 按优先级处理 FAIL
$priorityOrder = @('N1-1','N1-2','N4-1','N4-2','N4-3','N3-1','N3-2','N3-3','N2-1','N2-2','N2-3','N5-1','N5-2')

$fixed = 0
$skipped = 0

function Restart-ListenerWatchdog {
  # kill 现有 listener + watchdog
  Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*ntfy-inbox-listener*' -or $_.CommandLine -like '*run-ntfy-listener*' } |
    ForEach-Object {
      Write-Host "  [KILL] PID=$($_.ProcessId)" -ForegroundColor DarkGray
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
  Start-Sleep -Milliseconds 500
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass',
    '-File', "$env:USERPROFILE\.claude\hooks\run-ntfy-listener.ps1"
  )
  Start-Sleep 1
}

foreach ($id in $priorityOrder) {
  $check = $failed | Where-Object Id -eq $id | Select-Object -First 1
  if (-not $check) { continue }
  if ($Section -ne 'all' -and -not $id.StartsWith($Section)) { continue }

  Write-Host "→ $id $($check.Title): $($check.Detail)" -ForegroundColor Yellow

  switch ($id) {
    'N1-1' {
      Write-Host "  [SKIP] server 不可达不能 PC 端修，去 SSH aliyun 看 systemctl status ntfy" -ForegroundColor DarkGray
      $skipped++
    }
    'N1-2' {
      Write-Host "  [SKIP] token 失效不能 PC 端自动修，SSH aliyun 跑 ntfy access + ntfy token add" -ForegroundColor DarkGray
      $skipped++
    }
    { $_ -in 'N4-1','N4-2' } {
      if (Confirm-Action "清死 slot（跑 ntfy-slot-release.ps1）") {
        & "$env:USERPROFILE\.claude\hooks\ntfy-slot-release.ps1"
        $fixed++
      } else { $skipped++ }
    }
    'N3-1' {
      if (Confirm-Action "启动 AHK injector") {
        & "$ScriptsDir\restart-ahk.ps1"
        $fixed++
      } else { $skipped++ }
    }
    'N3-2' {
      if (Confirm-Action "重启 AHK（假死）") {
        & "$ScriptsDir\restart-ahk.ps1"
        $fixed++
      } else { $skipped++ }
    }
    'N2-1' {
      if (Confirm-Action "启动 listener watchdog") {
        Restart-ListenerWatchdog
        $fixed++
      } else { $skipped++ }
    }
    'N2-2' {
      if (Confirm-Action "重启 listener（假死/无活动）") {
        Restart-ListenerWatchdog
        $fixed++
      } else { $skipped++ }
    }
    'N2-3' {
      if (Confirm-Action "清重复 listener（保留 watchdog 启动的最新一个）") {
        $listeners = @(Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
          Where-Object { $_.CommandLine -like '*ntfy-inbox-listener*' } |
          Sort-Object CreationDate)
        # 留最后一个，前面的 kill
        for ($i = 0; $i -lt $listeners.Count - 1; $i++) {
          Stop-Process -Id $listeners[$i].ProcessId -Force -ErrorAction SilentlyContinue
          Write-Host "  [KILL] 重复 listener PID=$($listeners[$i].ProcessId)" -ForegroundColor DarkGray
        }
        $fixed++
      } else { $skipped++ }
    }
    'N5-1' {
      Write-Host "  [MANUAL] settings.json 里 Notification 段含 ntfy-stop.ps1，需手动改" -ForegroundColor Yellow
      Write-Host "  打开: $env:USERPROFILE\.claude\settings.json"
      Write-Host "  删除 Notification 段下含 ntfy-stop.ps1 的条目（保留声音 hook）"
      $skipped++
    }
    'N5-2' {
      if (Confirm-Action "重建 Startup 快捷方式（跑 setup.ps1 startup）") {
        & "$ScriptsDir\setup.ps1" -Stage startup
        $fixed++
      } else { $skipped++ }
    }
    default {
      Write-Host "  [TODO] $id 自动修复未实现" -ForegroundColor DarkGray
      Write-Host "  推荐手动: $($check.Fix)" -ForegroundColor DarkGray
      $skipped++
    }
  }
  Write-Host ""
}

# 3. 处理 WARN（preventive）
foreach ($id in @('N3-3')) {
  $check = $warned | Where-Object Id -eq $id | Select-Object -First 1
  if (-not $check) { continue }

  Write-Host "→ $id (WARN) $($check.Title): $($check.Detail)" -ForegroundColor Yellow
  switch ($id) {
    'N3-3' {
      if (Confirm-Action "重启 AHK（预防性，>12h 状态漂移）") {
        & "$ScriptsDir\restart-ahk.ps1"
        $fixed++
      } else { $skipped++ }
    }
  }
  Write-Host ""
}

Write-Host ""
Write-Host "修复完成: $fixed 项已修 / $skipped 项跳过" -ForegroundColor Green
Write-Host ""
Write-Host "建议: 跑 /gen-ntfy doctor 复验" -ForegroundColor Cyan
