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

# Load slots registry, check if this HWND already claimed (don't double-bind same window)
$reg = Get-Content -Raw -Encoding UTF8 $slotsFile | ConvertFrom-Json
$claimed = $null
foreach ($name in 'slot-1','slot-2','slot-3','slot-4','slot-5','slot-6','slot-7','slot-8','slot-9') {
    $slot = $reg.slots.$name
    if ($slot.hwnd -eq $found.hwnd) {
        Log "HWND $($found.hwnd) already in $name (skip duplicate claim, but reset tab title)"
        Write-Host "[INFO] this WT window (HWND=$($found.hwnd)) is already bound to $name" -ForegroundColor Yellow
        $slot.session_id = $sessionId
        $tmp = "$slotsFile.tmp"
        $reg | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $slotsFile -Force
        # Re-set tab title (in case it was overwritten)
        $slotTag = "[$name] cc"
        [Console]::Write("$([char]27)]0;$slotTag$([char]7)")
        Write-Host "Tab title re-set to: '$slotTag'" -ForegroundColor Cyan
        $name
        exit 0
    }
}
foreach ($name in 'slot-1','slot-2','slot-3','slot-4','slot-5','slot-6','slot-7','slot-8','slot-9') {
    $slot = $reg.slots.$name
    if (-not $slot.hwnd) {
        # Free, claim it
        $slot.hwnd = $found.hwnd
        $slot.pid  = $found.pid
        $slot.session_id = $sessionId
        $slot.claimed_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        $slot.label = "$($found.name) PID=$($found.pid)"
        $claimed = $name
        break
    }
}

if (-not $claimed) {
    Log "no free slot (all 7 occupied)"
    Write-Host "[FAIL] all slots occupied; manually release via ntfy-slot-release.ps1 or edit slots.json" -ForegroundColor Yellow
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
