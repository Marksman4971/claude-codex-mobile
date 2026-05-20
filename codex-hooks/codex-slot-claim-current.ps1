param(
    [switch]$FromHook,
    [switch]$Newest,
    [string]$ThreadId,
    [Int64]$Hwnd,
    [string]$Slot
)

$ErrorActionPreference = "Stop"

$slotsFile = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
$logFile = "$env:USERPROFILE\.codex\hooks\codex-slot-claim-current.log"

function Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $logFile -Value "[$ts] [CLAIM] $Message" -Encoding UTF8
}

function Get-Value {
    param(
        [object]$Object,
        [string[]]$Names
    )
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne "") {
            return [string]$prop.Value
        }
    }
    return $null
}

function Get-NewestCodexThreadId {
    $root = "$env:USERPROFILE\.codex\sessions"
    if (-not (Test-Path -LiteralPath $root)) { return $null }

    $files = Get-ChildItem -LiteralPath $root -Recurse -Filter "rollout-*.jsonl" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    foreach ($file in $files) {
        try {
            $line = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -TotalCount 1
            if (-not $line) { continue }
            $entry = $line | ConvertFrom-Json
            $id = Get-Value -Object $entry.payload -Names @("id", "thread_id", "threadId", "session_id", "sessionId")
            if ($id) { return $id }
        } catch {
            Log "newest thread parse failed: $($file.FullName) :: $($_.Exception.Message)"
        }
    }

    return $null
}

function Get-CodexWindow {
    param([Int64]$ExplicitHwnd)

    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class CodexWin {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}
"@ -ErrorAction SilentlyContinue

    if ($ExplicitHwnd -gt 0) {
        $explicitPtr = [IntPtr]$ExplicitHwnd
        $explicitPid = 0
        [void][CodexWin]::GetWindowThreadProcessId($explicitPtr, [ref]$explicitPid)

        $titleLen = [CodexWin]::GetWindowTextLength($explicitPtr)
        $titleSb = New-Object System.Text.StringBuilder ($titleLen + 1)
        [void][CodexWin]::GetWindowText($explicitPtr, $titleSb, $titleSb.Capacity)
        $explicitTitle = $titleSb.ToString()

        $explicitProc = $null
        if ($explicitPid -gt 0) {
            $explicitProc = Get-Process -Id $explicitPid -ErrorAction SilentlyContinue
        }

        $resolvedPid = if ($explicitPid -gt 0) { [int]$explicitPid } else { $null }
        $resolvedName = if ($explicitProc) { $explicitProc.ProcessName } else { "Codex" }
        $resolvedTitle = if ($explicitTitle) { $explicitTitle } else { "explicit" }

        return [pscustomobject]@{
            hwnd = $ExplicitHwnd
            pid = $resolvedPid
            name = $resolvedName
            title = $resolvedTitle
        }
    }

    # NEW (2026-05-20): Before GetForegroundWindow heuristic, prefer the slot that AHK
    # just injected into within the last 60s. Reason: when phone sends to slot-N, AHK
    # injects into slot-N's window, Codex processes in background, Stop hook fires while
    # user might be looking at a different window. GetForegroundWindow would route the
    # response to whatever the user is looking at (wrong); the recently-injected slot is
    # almost certainly the right window for the response.
    try {
        $slotsPath = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
        if (Test-Path -LiteralPath $slotsPath) {
            $reg2 = Get-Content -LiteralPath $slotsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $now = Get-Date
            $bestSlot = $null
            $bestTime = [datetime]::MinValue
            foreach ($n in 'slot-1','slot-2','slot-3','slot-4','slot-5','slot-6','slot-7','slot-8','slot-9','slot-10','slot-11','slot-12','slot-13','slot-14','slot-15','slot-16','slot-17','slot-18','slot-19','slot-20') {
                $sp = $reg2.slots.PSObject.Properties[$n]
                if (-not $sp) { continue }
                $s = $sp.Value
                if ($s.label -notlike "Codex Desktop*") { continue }
                if (-not $s.hwnd) { continue }
                if (-not $s.last_inject_at) { continue }
                $t = $null
                try { $t = [datetime]::ParseExact([string]$s.last_inject_at, 'yyyy-MM-dd HH:mm:ss', $null) } catch { continue }
                $diffSec = ($now - $t).TotalSeconds
                if ($diffSec -lt 0 -or $diffSec -gt 60) { continue }
                if ([CodexWin]::IsWindow([IntPtr]([Int64]$s.hwnd)) -and $t -gt $bestTime) {
                    $bestTime = $t
                    $bestSlot = $s
                }
            }
            if ($bestSlot) {
                Log "recent-inject hint: using slot HWND=$($bestSlot.hwnd) (last_inject_at=$($bestSlot.last_inject_at)) instead of GetForegroundWindow"
                return [pscustomobject]@{
                    hwnd = [int64]$bestSlot.hwnd
                    pid = [int]$bestSlot.pid
                    name = "Codex"
                    title = "recent-inject"
                }
            }
        }
    } catch {
        Log "recent-inject hint lookup failed (non-fatal): $($_.Exception.Message)"
    }

    $fgHwnd = [CodexWin]::GetForegroundWindow()
    if ($fgHwnd -ne [IntPtr]::Zero) {
        $fgPid = 0
        [void][CodexWin]::GetWindowThreadProcessId($fgHwnd, [ref]$fgPid)
        $titleLen = [CodexWin]::GetWindowTextLength($fgHwnd)
        $titleSb = New-Object System.Text.StringBuilder ($titleLen + 1)
        [void][CodexWin]::GetWindowText($fgHwnd, $titleSb, $titleSb.Capacity)
        $fgTitle = $titleSb.ToString()
        $fgProc = (Get-Process -Id $fgPid -ErrorAction SilentlyContinue).ProcessName

        if ($fgProc -match "^Codex$|^ChatGPT$" -or $fgTitle -match "Codex") {
            return [pscustomobject]@{
                hwnd = [int64]$fgHwnd
                pid = [int]$fgPid
                name = $fgProc
                title = $fgTitle
            }
        }
    }

    $codex = Get-Process -Name Codex -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1

    if ($codex) {
        return [pscustomobject]@{
            hwnd = [int64]$codex.MainWindowHandle
            pid = [int]$codex.Id
            name = $codex.ProcessName
            title = $codex.MainWindowTitle
        }
    }

    return $null
}

if ($FromHook) {
    try {
        $ms = New-Object System.IO.MemoryStream
        [Console]::OpenStandardInput().CopyTo($ms)
        $stdin = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        if ($stdin) {
            $hook = $stdin | ConvertFrom-Json
            $fromPayload = Get-Value -Object $hook -Names @(
                "session_id",
                "sessionId",
                "thread_id",
                "threadId",
                "conversation_id",
                "conversationId"
            )
            if ($fromPayload) { $ThreadId = $fromPayload }
        }
    } catch {
        Log "stdin parse failed: $($_.Exception.Message)"
    }
}

if (-not $ThreadId -and -not $Newest) {
    $ThreadId = $env:CODEX_THREAD_ID
}

if (-not $ThreadId) {
    $ThreadId = Get-NewestCodexThreadId
}

if (-not $ThreadId) {
    Log "no thread id found"
    Write-Host "[FAIL] no Codex thread id found" -ForegroundColor Red
    exit 1
}

$window = Get-CodexWindow -ExplicitHwnd $Hwnd
if (-not $window) {
    Log "no Codex window found for thread=$ThreadId"
    Write-Host "[FAIL] no Codex window found" -ForegroundColor Red
    exit 2
}

if (-not (Test-Path -LiteralPath $slotsFile)) {
    Log "slots file missing: $slotsFile"
    Write-Host "[FAIL] slots file missing: $slotsFile" -ForegroundColor Red
    exit 3
}

$reg = Get-Content -LiteralPath $slotsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$slotNames = @("slot-1","slot-2","slot-3","slot-4","slot-5","slot-6","slot-7","slot-8","slot-9","slot-10","slot-11","slot-12","slot-13","slot-14","slot-15","slot-16","slot-17","slot-18","slot-19","slot-20")

foreach ($name in $slotNames) {
    $slotObj = $reg.slots.$name
    if ($slotObj.label -notlike "Codex Desktop*") { continue }

    $pidAlive = $false
    if ($slotObj.pid) {
        $pidAlive = [bool](Get-Process -Id $slotObj.pid -ErrorAction SilentlyContinue)
    }

    $hwndAlive = $false
    if ($slotObj.hwnd) {
        $hwndAlive = [CodexWin]::IsWindow([IntPtr]([Int64]$slotObj.hwnd))
    }

    if (-not $pidAlive -or -not $hwndAlive) {
        Log "clearing stale $name pid=$($slotObj.pid) hwnd=$($slotObj.hwnd) session=$($slotObj.session_id)"
        $slotObj.hwnd = $null
        $slotObj.pid = $null
        $slotObj.session_id = $null
        $slotObj.claimed_at = $null
        $slotObj.label = $null
    }
}

$target = $null

# PASS 1: explicit -Slot override
if ($Slot -and $slotNames -contains $Slot) {
    $target = $Slot
}

# PASS 2: same thread_id (continuation of same conversation)
if (-not $target) {
    foreach ($name in $slotNames) {
        $slotObj = $reg.slots.$name
        if ($slotObj.session_id -eq $ThreadId) {
            $target = $name
            break
        }
    }
}

# PASS 3 (NEW, 2026-05-20): same Codex window (HWND match) but thread switched.
# Codex Desktop fires SessionStart hook every time user opens/switches a thread,
# even within the SAME Electron window. Without this pass, switching threads in
# one window claims a NEW slot per thread → multiple slots all bound to same HWND
# → AHK can't disambiguate → all phone messages route to whichever thread is visible.
# Rule: 1 Codex window = 1 slot. Switching threads inside a window just refreshes
# that slot's session_id to track the now-visible thread.
if (-not $target) {
    foreach ($name in $slotNames) {
        $slotObj = $reg.slots.$name
        if ($slotObj.hwnd -and $slotObj.hwnd -eq $window.hwnd -and $slotObj.label -like "Codex Desktop*") {
            $target = $name
            Log "rebinding $name (same Codex window HWND=$($window.hwnd), thread updated from $($slotObj.session_id) to $ThreadId)"
            Write-Host "[INFO] reusing $name (same Codex window, thread rebind to $ThreadId)" -ForegroundColor Yellow
            break
        }
    }
}

# PASS 4: first truly-free slot (new Codex window, no existing binding)
if (-not $target) {
    foreach ($name in $slotNames) {
        $slotObj = $reg.slots.$name
        if (-not $slotObj.hwnd -and -not $slotObj.session_id) {
            $target = $name
            break
        }
    }
}

if (-not $target) {
    Log "no free slot for thread=$ThreadId"
    Write-Host "[FAIL] no free slot" -ForegroundColor Yellow
    exit 4
}

$slotRef = $reg.slots.$target
$slotRef.hwnd = $window.hwnd
$slotRef.pid = $window.pid
$slotRef.session_id = $ThreadId
$slotRef.claimed_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
$slotRef.label = "Codex Desktop PID=$($window.pid)"

# PASS 5 (NEW, 2026-05-20): scan ALL visible Codex windows, claim orphans automatically.
# Codex Desktop fires SessionStart on every thread open/switch. We piggyback on that to
# also bind any visible Codex BrowserWindow that has no slot yet — so a freshly opened
# 2nd Codex window gets auto-bound at next thread activity, no manual ntfy-slot-claim run.
function Enum-CodexWindows {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class CodexEnum {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
}
"@ -ErrorAction SilentlyContinue
    $codexPids = (Get-Process -Name Codex -ErrorAction SilentlyContinue).Id
    if (-not $codexPids -or $codexPids.Count -eq 0) { return @() }
    $result = New-Object 'System.Collections.Generic.List[object]'
    $cb = [CodexEnum+EnumProc] {
        param([IntPtr]$h, [IntPtr]$l)
        $procPid = 0
        [void][CodexEnum]::GetWindowThreadProcessId($h, [ref]$procPid)
        if ($codexPids -notcontains $procPid) { return $true }
        if (-not [CodexEnum]::IsWindowVisible($h)) { return $true }
        $owner = [CodexEnum]::GetWindow($h, 4)
        if ($owner -ne [IntPtr]::Zero) { return $true }  # skip child/owned windows
        $len = [CodexEnum]::GetWindowTextLength($h)
        if ($len -eq 0) { return $true }
        $sb = New-Object System.Text.StringBuilder ($len + 1)
        [void][CodexEnum]::GetWindowText($h, $sb, $sb.Capacity)
        $title = $sb.ToString()
        # only true Codex chat windows (title literally "Codex" or starts with "Codex")
        if ($title -notlike "Codex*" -and $title -ne "ChatGPT") { return $true }
        $result.Add([PSCustomObject]@{ Hwnd = [int64]$h; Pid = [int]$procPid; Title = $title })
        return $true
    }
    [void][CodexEnum]::EnumWindows($cb, [IntPtr]::Zero)
    return $result
}

try {
    $allCodexWins = Enum-CodexWindows
    $boundHwnds = @($slotNames | ForEach-Object { $reg.slots.$_.hwnd } | Where-Object { $_ })
    foreach ($win in $allCodexWins) {
        if ($boundHwnds -contains $win.Hwnd) { continue }   # already bound somewhere
        # find first free slot
        $orphanTarget = $null
        foreach ($name in $slotNames) {
            if (-not $reg.slots.$name.hwnd -and -not $reg.slots.$name.session_id) {
                $orphanTarget = $name; break
            }
        }
        if (-not $orphanTarget) {
            Log "PASS5 orphan scan: no free slot for unmapped Codex window HWND=$($win.Hwnd) title='$($win.Title)'"
            break
        }
        $oRef = $reg.slots.$orphanTarget
        $oRef.hwnd = $win.Hwnd
        $oRef.pid = $win.Pid
        $oRef.session_id = "auto-scanned-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $oRef.claimed_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        $oRef.label = "Codex Desktop PID=$($win.Pid) (auto-orphan-bind)"
        $boundHwnds += $win.Hwnd
        Log "PASS5 auto-bound orphan Codex window: $orphanTarget topic=$($oRef.topic) hwnd=$($win.Hwnd) title='$($win.Title)'"
        Write-Host "[INFO] PASS5 auto-bound orphan Codex window to $orphanTarget (HWND=$($win.Hwnd))" -ForegroundColor Cyan
    }
} catch {
    Log "PASS5 orphan scan failed (non-fatal): $($_.Exception.Message)"
}

$tmp = "$slotsFile.tmp"
$reg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $slotsFile -Force

Log "claimed $target topic=$($slotRef.topic) thread=$ThreadId hwnd=$($window.hwnd) pid=$($window.pid) title='$($window.title)'"
Write-Host "[OK] claimed $target -> $($slotRef.topic)"
Write-Host "thread=$ThreadId"
Write-Host "hwnd=$($window.hwnd)"
