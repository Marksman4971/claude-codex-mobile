<#
.SYNOPSIS
  gen-ntfy doctor: 全链路扫描 PASS/WARN/FAIL 报告 + 推荐 action

.PARAMETER Quick
  跳过慢检查（server health + token verify），3s 内出报告

.PARAMETER Json
  输出 JSON 格式（机读）

.PARAMETER Section
  只跑某一类：N1 server / N2 listener / N3 ahk / N4 slot / N5 hook / N6 route
#>
[CmdletBinding()]
param(
  [switch]$Quick,
  [switch]$Json,
  [ValidateSet('all','N1','N2','N3','N4','N5','N6')]
  [string]$Section = 'all'
)

$ErrorActionPreference = 'Continue'

# Win32 IsWindow 用于 N4-2 HWND 失效检测
if (-not ('GenNtfyWin32' -as [type])) {
  Add-Type -Namespace GenNtfy -Name Win32 -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool IsWindow(System.IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool IsWindowVisible(System.IntPtr hWnd);
'@ 2>$null
}

$HooksDir = "$env:USERPROFILE\.claude\hooks"
$SlotsJson = "$HooksDir\ntfy-slots.json"
$InboxLog = "$HooksDir\ntfy-inbox-debug.txt"
$InjectorLog = "$HooksDir\ntfy-injector.log"
$SettingsJson = "$env:USERPROFILE\.claude\settings.json"
$NtfyServer = '${NTFY_SERVER_URL}'
$CodexDispatch = "$env:USERPROFILE\.codex\hooks\codex-ntfy-dispatch.ps1"

# token 从 ntfy-stop.ps1 抽
$Token = $null
try {
  $stopContent = Get-Content "$HooksDir\ntfy-stop.ps1" -Raw -ErrorAction SilentlyContinue
  if ($stopContent -match 'Bearer\s+(tk_[A-Za-z0-9_-]+)') {
    $Token = $Matches[1]
  }
} catch {}

$Report = @()

function Add-Check {
  param(
    [string]$Id,
    [string]$Title,
    [ValidateSet('PASS','WARN','FAIL')]
    [string]$Status,
    [string]$Detail = '',
    [string]$Fix = ''
  )
  $script:Report += [PSCustomObject]@{
    Id     = $Id
    Title  = $Title
    Status = $Status
    Detail = $Detail
    Fix    = $Fix
  }
}

# ============ §1 Server / 网络 ============
if ($Section -in 'all','N1') {
  # N1-1: server health
  if (-not $Quick) {
    try {
      $h = curl.exe -s --max-time 5 "$NtfyServer/v1/health" 2>$null
      if ($h -match '"healthy":true') {
        Add-Check 'N1-1' 'server 可达' PASS "health endpoint OK"
      } else {
        Add-Check 'N1-1' 'server 可达' FAIL "health endpoint 异常: $h" "检查 SSH aliyun + systemctl status ntfy"
      }
    } catch {
      Add-Check 'N1-1' 'server 可达' FAIL "curl 异常: $_" "检查本地网络/代理 + server 端"
    }

    # N1-2: token 写权限。发到 listener 不订阅的 noop topic，server 验证 token 但不下发 → 不骚扰任何 cc 窗口
    if ($Token) {
      $probeTopic = '${NTFY_TOPIC_PREFIX}-doctor-noop'
      $payload = "[gen-ntfy doctor probe - 测试探针请忽略 - $(Get-Date -Format 'HH:mm:ss')]"
      $code = curl.exe -s -o NUL -w "%{http_code}" -X POST `
        -H "Authorization: Bearer $Token" --data $payload `
        "$NtfyServer/$probeTopic" 2>$null
      if ($code -eq '200') {
        Add-Check 'N1-2' 'token 写权限' PASS "POST $probeTopic 200（未订阅 topic 不下发）"
      } else {
        Add-Check 'N1-2' 'token 写权限' FAIL "$probeTopic HTTP=$code" "SSH aliyun 查 ntfy access，重新授权"
      }
    } else {
      Add-Check 'N1-2' 'token 写权限' WARN "无法从 ntfy-stop.ps1 抽取 token" "检查 ntfy-stop.ps1 是否含 Bearer tk_ 字段"
    }
  }
}

# ============ §2 Listener / Watchdog ============
if ($Section -in 'all','N2') {
  $listenerProcs = @(Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*ntfy-inbox-listener*' })
  $watchdogProcs = @(Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*run-ntfy-listener*' })

  # N2-1: listener 进程存在
  if ($listenerProcs.Count -ge 1) {
    Add-Check 'N2-1' 'listener 进程存在' PASS "PID=$($listenerProcs[0].ProcessId)"
  } else {
    Add-Check 'N2-1' 'listener 进程存在' FAIL "未找到 ntfy-inbox-listener powershell" "启动 watchdog（Startup 快捷方式 / 手动 spawn run-ntfy-listener.ps1）"
  }

  # N2-3: 多 listener 重复
  if ($listenerProcs.Count -ge 2) {
    Add-Check 'N2-3' 'listener 唯一性' WARN "$($listenerProcs.Count) 个 listener 并行" "kill 多余，保留 watchdog 启动的"
  } elseif ($listenerProcs.Count -eq 1) {
    Add-Check 'N2-3' 'listener 唯一性' PASS "只有 1 个 listener"
  }

  # N2-2: listener 近期活动
  if (Test-Path $InboxLog) {
    $lastModified = (Get-Item $InboxLog).LastWriteTime
    $age = (Get-Date) - $lastModified
    if ($age.TotalMinutes -lt 5) {
      Add-Check 'N2-2' 'listener 近期活动' PASS "log 上次更新 $([int]$age.TotalSeconds)s 前"
    } elseif ($age.TotalMinutes -lt 30) {
      Add-Check 'N2-2' 'listener 近期活动' WARN "log 上次更新 $([int]$age.TotalMinutes)min 前（可能正常 idle）"
    } else {
      Add-Check 'N2-2' 'listener 近期活动' WARN "log 上次更新 >$([int]$age.TotalMinutes)min 前" "可能假死，kill + watchdog 重启"
    }
  } else {
    Add-Check 'N2-2' 'listener 近期活动' WARN "未找到 listener log" "确认 listener 启动后日志路径"
  }
}

# ============ §3 AHK Injector ============
if ($Section -in 'all','N3') {
  $ahk = @(Get-Process AutoHotkey64 -ErrorAction SilentlyContinue)

  # N3-1: AHK 进程存在
  if ($ahk.Count -eq 0) {
    Add-Check 'N3-1' 'AHK 进程存在' FAIL "未找到 AutoHotkey64" "Startup 启动 / 手动 Start-Process ntfy-injector.ahk"
  } else {
    $a = $ahk[0]
    Add-Check 'N3-1' 'AHK 进程存在' PASS "PID=$($a.Id) Started=$($a.StartTime.ToString('HH:mm:ss'))"

    if ($ahk.Count -gt 1) {
      Add-Check 'N3-5' 'AHK 唯一性' FAIL "$($ahk.Count) 个 AutoHotkey64 进程: $($ahk.Id -join ', ')" "/gen-ntfy restart 清理为单实例"
    } else {
      Add-Check 'N3-5' 'AHK 唯一性' PASS "只有 1 个 AHK injector"
    }

    # N3-2: AHK 响应性
    if (-not $a.Responding) {
      Add-Check 'N3-2' 'AHK 响应' FAIL "Responding=False（假死）" "/gen-ntfy restart（kill + 重启 AHK）"
    } else {
      Add-Check 'N3-2' 'AHK 响应' PASS "Responding=True"
    }

    # N3-3: AHK 老化
    $uptime = (Get-Date) - $a.StartTime
    if ($uptime.TotalHours -gt 12) {
      Add-Check 'N3-3' 'AHK 状态新鲜度' WARN "已跑 $([int]$uptime.TotalHours)h（>12h 状态漂移高发）" "/gen-ntfy restart 主动重启"
    } else {
      Add-Check 'N3-3' 'AHK 状态新鲜度' PASS "已跑 $([int]$uptime.TotalMinutes)min"
    }
  }

  # N3 综合：近期注入成功率（用 injector log）
  if (Test-Path $InjectorLog) {
    $tail = Get-Content $InjectorLog -Tail 50 -ErrorAction SilentlyContinue
    $recent = $tail | Where-Object { $_ -match '^\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\]' }
    if ($recent) {
      $lastInjectLine = $tail | Where-Object { $_ -match 'HWND injected' } | Select-Object -Last 1
      if ($lastInjectLine -and $lastInjectLine -match '^\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\]') {
        $lastInject = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
        $lastAge = (Get-Date) - $lastInject
        if ($lastAge.TotalMinutes -lt 10) {
          Add-Check 'N3-4' 'AHK 近期注入' PASS "最近一次注入 $([int]$lastAge.TotalMinutes)min 前"
        } else {
          Add-Check 'N3-4' 'AHK 近期注入' WARN "最近一次注入 >$([int]$lastAge.TotalMinutes)min 前（可能空窗或漂移）"
        }
      }
    }
  }
}

# ============ §4 Slot 表 / HWND ============
if ($Section -in 'all','N4') {
  if (-not (Test-Path $SlotsJson)) {
    Add-Check 'N4-0' 'slots.json 存在' FAIL "找不到 $SlotsJson" "/gen-ntfy setup hooks 重建"
  } else {
    $slots = (Get-Content $SlotsJson -Raw | ConvertFrom-Json).slots
    $deadPids = @()
    $invalidHwnds = @()
    $hwndUsage = @{}
    foreach ($slot in $slots.PSObject.Properties) {
      $s = $slot.Value
      if ($s.pid) {
        $proc = Get-Process -Id $s.pid -ErrorAction SilentlyContinue
        if (-not $proc) { $deadPids += $slot.Name }
        if ($s.hwnd) {
          # N4-2: HWND Win32 API 校验
          try {
            $h = [IntPtr]([int64]$s.hwnd)
            if (-not [GenNtfy.Win32]::IsWindow($h)) {
              $invalidHwnds += "$($slot.Name)=hwnd($($s.hwnd))无效"
            }
          } catch {
            $invalidHwnds += "$($slot.Name)=hwnd检查异常"
          }
          if (-not $hwndUsage.ContainsKey($s.hwnd)) { $hwndUsage[$s.hwnd] = @() }
          $hwndUsage[$s.hwnd] += $slot.Name
        }
      }
    }

    # N4-1: 死 PID
    if ($deadPids.Count -eq 0) {
      Add-Check 'N4-1' 'slot 表无死 PID' PASS "所有 claimed slot 的 PID 活"
    } else {
      Add-Check 'N4-1' 'slot 表无死 PID' FAIL "死 PID: $($deadPids -join ', ')" "ntfy-slot-release.ps1（manual mode 自动清死锁）"
    }

    # N4-2: HWND Win32 失效
    if ($invalidHwnds.Count -eq 0) {
      Add-Check 'N4-2' 'slot HWND 有效' PASS "所有 HWND 通过 Win32 IsWindow"
    } else {
      Add-Check 'N4-2' 'slot HWND 有效' FAIL ($invalidHwnds -join ', ') "ntfy-slot-release.ps1 清后让新 SessionStart 重新 claim"
    }

    # N4-3: HWND 复用。Codex Desktop 天然多 thread 共享一个 Electron HWND。
    # app-server dispatcher 已降级为 opt-in，因为它会跑后台 turn，不会进入当前窗口；
    # 所以 Codex Desktop 共享 HWND 只能算 best-effort，不再给假 PASS。
    $shared = $hwndUsage.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }
    $unsafeShared = @()
    $codexShared = @()
    foreach ($entry in $shared) {
      $allCodex = $true
      foreach ($slotName in $entry.Value) {
        if ($slots.$slotName.label -notlike 'Codex Desktop*') { $allCodex = $false }
      }
      $detail = "HWND=$($entry.Key)→[$($entry.Value -join ',')]"
      if ($allCodex) { $codexShared += $detail } else { $unsafeShared += $detail }
    }
    if ($unsafeShared.Count -eq 0 -and $codexShared.Count -eq 0) {
      Add-Check 'N4-3' 'slot HWND 不复用' PASS "每个 HWND 仅 1 slot"
    } elseif ($unsafeShared.Count -eq 0) {
      Add-Check 'N4-3' 'slot HWND 不复用' WARN "Codex Desktop 共享 HWND（$($codexShared -join '; ')）；clipboard/AHK 对当前 Codex 窗口为 best-effort" "保留当前默认链路；Codex 前台注入需另做验证后再启用"
    } else {
      Add-Check 'N4-3' 'slot HWND 不复用' WARN ($unsafeShared -join '; ') "保留 1 slot 释放其余 / 用独立 WT 窗口"
    }
  }
}

# ============ §5 Hook / 配置 ============
if ($Section -in 'all','N5') {
  # N5-1: Stop hook 双注册检查
  if (Test-Path $SettingsJson) {
    $settings = Get-Content $SettingsJson -Raw -ErrorAction SilentlyContinue
    $stopInNotification = $settings -match '"Notification"[\s\S]*?ntfy-stop'
    if ($stopInNotification) {
      Add-Check 'N5-1' 'Stop hook 单注册' FAIL "ntfy-stop.ps1 也挂在 Notification 段（双推送）" "从 Notification 段删除 ntfy-stop.ps1"
    } else {
      Add-Check 'N5-1' 'Stop hook 单注册' PASS "ntfy-stop 只在 Stop 段"
    }
  } else {
    Add-Check 'N5-1' 'Stop hook 单注册' WARN "settings.json 不存在" "/gen-ntfy setup settings"
  }

  # N5-2: Startup 快捷方式
  $startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
  $hasInjector = Test-Path "$startup\ntfy-injector.lnk"
  $hasWatchdog = Test-Path "$startup\ntfy-listener-watchdog.lnk"
  if ($hasInjector -and $hasWatchdog) {
    Add-Check 'N5-2' 'Startup 快捷方式齐' PASS "ntfy-injector.lnk + ntfy-listener-watchdog.lnk 都在"
  } else {
    $missing = @()
    if (-not $hasInjector) { $missing += 'ntfy-injector.lnk' }
    if (-not $hasWatchdog) { $missing += 'ntfy-listener-watchdog.lnk' }
    Add-Check 'N5-2' 'Startup 快捷方式齐' WARN "缺: $($missing -join ', ')" "/gen-ntfy setup startup 重建"
  }
}

# ============ §6 Route hardening ============
if ($Section -in 'all','N6') {
  $listener = Get-Content "$HooksDir\ntfy-inbox-listener.ps1" -Raw -ErrorAction SilentlyContinue
  $dispatchOk = Test-Path -LiteralPath $CodexDispatch
  $dispatchText = ''
  if ($dispatchOk) { $dispatchText = Get-Content -LiteralPath $CodexDispatch -Raw -ErrorAction SilentlyContinue }
  $listenerRoutesCodex = $listener -match 'Queue-CodexInbound' -and $listener -match 'codex-ntfy-dispatch'
  $listenerDispatchOptIn = $listener -match 'NTFY_CODEX_APP_SERVER_DISPATCH' -and $listener -match 'EnableCodexAppServerDispatch'
  $dispatchUtf8Safe = $dispatchText -match 'ConvertTo-JsonRpcAscii'
  $dispatchWaitsForTurn = $dispatchText -match 'task_started' -and $dispatchText -match 'task_complete'
  if ($listenerDispatchOptIn) {
    Add-Check 'N6-5' 'Codex 入站协议路由' PASS "app-server route 已降级为 opt-in；默认不截流手机消息"
  } elseif (-not $dispatchOk) {
    Add-Check 'N6-5' 'Codex 入站协议路由' WARN "缺少 $CodexDispatch；当前使用 clipboard/AHK 默认链路" "仅在明确需要实验 app-server route 时部署 dispatcher"
  } elseif (-not $listenerRoutesCodex) {
    Add-Check 'N6-5' 'Codex 入站协议路由' PASS "listener 未启用 app-server 分流；默认使用 clipboard/AHK"
  } elseif (-not $dispatchUtf8Safe) {
    Add-Check 'N6-5' 'Codex 入站协议路由' WARN "dispatcher 未做 JSON-RPC ASCII 转义，中文会破坏 app-server stdin" "app-server route 仍为实验；保留默认 clipboard/AHK"
  } elseif (-not $dispatchWaitsForTurn) {
    Add-Check 'N6-5' 'Codex 入站协议路由' WARN "dispatcher 未按 task_started/task_complete 判断当前 turn 是否空闲" "app-server route 仍为实验；保留默认 clipboard/AHK"
  } else {
    Add-Check 'N6-5' 'Codex 入站协议路由' WARN "app-server route 可用但不应默认启用；它会产生后台 turn，不会进入当前窗口" "把 listener 改为 NTFY_CODEX_APP_SERVER_DISPATCH opt-in"
  }
}

# ============ 输出 ============
if ($Json) {
  $passCount = @($Report | Where-Object Status -eq 'PASS').Count
  $warnCount = @($Report | Where-Object Status -eq 'WARN').Count
  $failCount = @($Report | Where-Object Status -eq 'FAIL').Count
  @{
    timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    summary = @{ pass=$passCount; warn=$warnCount; fail=$failCount }
    checks = $Report
  } | ConvertTo-Json -Depth 5
} else {
  $colors = @{ PASS='Green'; WARN='Yellow'; FAIL='Red' }
  Write-Host ""
  Write-Host "===== gen-ntfy doctor =====" -ForegroundColor Cyan
  Write-Host "时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  Write-Host ""
  foreach ($r in $Report) {
    $tag = "[$($r.Status)]"
    Write-Host -NoNewline "$tag " -ForegroundColor $colors[$r.Status]
    Write-Host "$($r.Id) $($r.Title)" -NoNewline
    if ($r.Detail) { Write-Host " — $($r.Detail)" -ForegroundColor Gray } else { Write-Host "" }
    if ($r.Status -ne 'PASS' -and $r.Fix) {
      Write-Host "       → $($r.Fix)" -ForegroundColor DarkGray
    }
  }
  Write-Host ""
  $passCount = @($Report | Where-Object Status -eq 'PASS').Count
  $warnCount = @($Report | Where-Object Status -eq 'WARN').Count
  $failCount = @($Report | Where-Object Status -eq 'FAIL').Count
  $summary = "汇总: $passCount PASS / $warnCount WARN / $failCount FAIL"
  if ($failCount -gt 0) {
    Write-Host $summary -ForegroundColor Red
    Write-Host "建议: /gen-ntfy fix 修 FAIL 项" -ForegroundColor Yellow
    exit 2
  } elseif ($warnCount -gt 0) {
    Write-Host $summary -ForegroundColor Yellow
    exit 1
  } else {
    Write-Host $summary -ForegroundColor Green
    exit 0
  }
}
