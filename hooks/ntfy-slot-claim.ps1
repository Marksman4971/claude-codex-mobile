# ntfy slot claim — bind current cc terminal to a free ntfy topic slot.
# Usage:
#   .\ntfy-slot-claim.ps1                 # manual mode, no stdin read
#   .\ntfy-slot-claim.ps1 -FromHook       # SessionStart hook mode, reads stdin payload
# (stdin reading wrapped in a Job is unreliable in some host contexts — opt-in only)

param([switch]$FromHook)

$ErrorActionPreference = 'Stop'

$slotsFile = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
$logFile   = "$env:USERPROFILE\.claude\hooks\ntfy-slot.log"

function Log {
    param([string]$m)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "[$ts] [CLAIM] $m" -Encoding UTF8
}

# Only attempt stdin read in hook mode (cc closes stdin after sending payload)
$sessionId = $null
if ($FromHook) {
    try {
        $ms = New-Object System.IO.MemoryStream
        [Console]::OpenStandardInput().CopyTo($ms)
        $stdin = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        if ($stdin) {
            $hook = $stdin | ConvertFrom-Json
            $sessionId = $hook.session_id
        }
    } catch { Log "stdin parse failed: $_" }
}

if (-not $sessionId) {
    $sessionId = "manual-$PID-$(Get-Date -Format 'yyMMddHHmmss')"
}
Log "session_id=$sessionId"

# PRIMARY: use foreground window at moment of claim — user runs claim inside the WT
# window they want bound, so foreground = correct WT window. Solves WT-multi-window-shared-PID
# problem where Process.MainWindowHandle is non-deterministic.
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WClaim {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}
"@ -ErrorAction SilentlyContinue

$fgHwnd = [WClaim]::GetForegroundWindow()
$fgPid = 0
[void][WClaim]::GetWindowThreadProcessId($fgHwnd, [ref]$fgPid)
$titleLen = [WClaim]::GetWindowTextLength($fgHwnd)
$titleSb = New-Object System.Text.StringBuilder ($titleLen + 1)
[void][WClaim]::GetWindowText($fgHwnd, $titleSb, $titleSb.Capacity)
$fgTitle = $titleSb.ToString()
$fgProc = (Get-Process -Id $fgPid -ErrorAction SilentlyContinue).ProcessName

$found = $null
if ($fgHwnd -ne [IntPtr]::Zero) {
    $found = @{ hwnd = [int64]$fgHwnd; pid = [int]$fgPid; name = $fgProc; title = $fgTitle }
    Log "foreground: pid=$fgPid hwnd=$([int64]$fgHwnd) name=$fgProc title='$fgTitle'"
} else {
    # FALLBACK: walk parent process tree
    Log "no foreground, falling back to process tree walk"
    $cur = $PID
    $walked = @()
    while ($cur -ne 0 -and $walked.Count -lt 20) {
        $walked += $cur
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        $sp = Get-Process -Id $cur -ErrorAction SilentlyContinue
        if ($sp -and $sp.MainWindowHandle -ne 0) {
            $found = @{ hwnd = [int64]$sp.MainWindowHandle; pid = $cur; name = $sp.ProcessName; title = $sp.MainWindowTitle }
            break
        }
        $cur = $p.ParentProcessId
    }
}

if (-not $found) {
    Log "no window found in parent chain $($walked -join '->')"
    Write-Host "[FAIL] no window found in parent process chain" -ForegroundColor Red
    exit 1
}
Log "window: pid=$($found.pid) hwnd=$($found.hwnd) name=$($found.name) title='$($found.title)'"

# Helper to check if a HWND still refers to a live window (orphan detection)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WChk { [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd); }
"@ -ErrorAction SilentlyContinue
function Test-LiveHwnd($h) {
    if (-not $h) { return $false }
    try { return [WChk]::IsWindow([IntPtr][int64]$h) } catch { return $false }
}

# Load slots registry
$reg = Get-Content -Raw -Encoding UTF8 $slotsFile | ConvertFrom-Json
$claimed = $null
$slotOrder = 'slot-1','slot-2','slot-3','slot-4','slot-5','slot-6','slot-7','slot-8','slot-9','slot-10','slot-11','slot-12','slot-13','slot-14','slot-15','slot-16','slot-17','slot-18','slot-19','slot-20'

# PASS 1: this exact HWND already in some slot → just refresh session_id + title (no rebinding)
foreach ($name in $slotOrder) {
    $slot = $reg.slots.$name
    if ($slot.hwnd -eq $found.hwnd) {
        Log "HWND $($found.hwnd) already in $name (skip duplicate claim, but reset tab title)"
        Write-Host "[INFO] this WT window (HWND=$($found.hwnd)) is already bound to $name" -ForegroundColor Yellow
        $slot.session_id = $sessionId
        $tmp = "$slotsFile.tmp"
        $reg | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $slotsFile -Force
        $slotTag = "[$name] cc"
        [Console]::Write("$([char]27)]0;$slotTag$([char]7)")
        Write-Host "Tab title re-set to: '$slotTag'" -ForegroundColor Cyan
        $name
        exit 0
    }
}

# PASS 2: prefer reclaiming an orphan slot (HWND set but window no longer alive) over
# allocating a fresh slot number. Keeps topic-to-cc binding stable across window churn:
# user closes cc, phone keeps subscribing slot-N, user opens new cc → it auto-reclaims
# slot-N → phone messages flow into the new window without changing subscription.
$reclaim = $null
$reclaimAge = $null
foreach ($name in $slotOrder) {
    $slot = $reg.slots.$name
    if ($slot.hwnd -and -not (Test-LiveHwnd $slot.hwnd)) {
        $ts = $null
        try { $ts = [datetime]::ParseExact($slot.claimed_at, 'yyyy-MM-dd HH:mm:ss', $null) } catch {}
        if (-not $reclaim -or ($ts -and $reclaimAge -and $ts -lt $reclaimAge)) {
            $reclaim = $name; $reclaimAge = $ts
        }
    }
}
if ($reclaim) {
    $slot = $reg.slots.$reclaim
    Log "reclaiming orphan slot $reclaim (was $($slot.label), dead hwnd=$($slot.hwnd))"
    Write-Host "[INFO] reclaiming orphan slot $reclaim (topic '$($slot.topic)' preserved across window churn)" -ForegroundColor Yellow
    $slot.hwnd = $found.hwnd
    $slot.pid  = $found.pid
    $slot.session_id = $sessionId
    $slot.claimed_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $slot.label = "$($found.name) PID=$($found.pid)"
    $claimed = $reclaim
}

# PASS 3: fall back to first truly-free slot (no hwnd at all)
if (-not $claimed) {
    foreach ($name in $slotOrder) {
        $slot = $reg.slots.$name
        if (-not $slot.hwnd) {
            $slot.hwnd = $found.hwnd
            $slot.pid  = $found.pid
            $slot.session_id = $sessionId
            $slot.claimed_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            $slot.label = "$($found.name) PID=$($found.pid)"
            $claimed = $name
            break
        }
    }
}

if (-not $claimed) {
    Log "no free or orphan slot (all 20 occupied with live windows)"
    Write-Host "[FAIL] all 9 slots occupied with live windows; release one via ntfy-slot-release.ps1" -ForegroundColor Yellow
    exit 2
}

# Write back atomically
$tmp = "$slotsFile.tmp"
$reg | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
Move-Item -Path $tmp -Destination $slotsFile -Force

Log "claimed $claimed (topic=$($reg.slots.$claimed.topic)) for hwnd=$($found.hwnd)"
Write-Host "[OK] claimed $claimed -> topic '$($reg.slots.$claimed.topic)' for cc window HWND=$($found.hwnd)" -ForegroundColor Green
Write-Host "Phone: subscribe to '$($reg.slots.$claimed.topic)' in ntfy app to send messages to this cc window"

# Set WT tab title via OSC escape sequence so AHK injector can find this tab via UIA.
# Works when run interactively (stdout goes to terminal). Won't work in hook mode (stdout captured by cc).
# Note: cc may overwrite this title back. Add "suppressApplicationTitle": true to your WT profile
# settings.json to prevent cc/PowerShell from overriding our slot tag.
$slotTag = "[$claimed] cc"
[Console]::Write("$([char]27)]0;$slotTag$([char]7)")
Write-Host ""
Write-Host "Tab title set to: '$slotTag' (add 'suppressApplicationTitle: true' to WT profile to make permanent)" -ForegroundColor Cyan

# Print the slot name for callers (hook scripts) to capture
$claimed
