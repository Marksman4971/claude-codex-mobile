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
$slotNames = @("slot-1","slot-2","slot-3","slot-4","slot-5","slot-6","slot-7","slot-8","slot-9")

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

if ($Slot -and $slotNames -contains $Slot) {
    $target = $Slot
}

if (-not $target) {
    foreach ($name in $slotNames) {
        $slotObj = $reg.slots.$name
        if ($slotObj.session_id -eq $ThreadId) {
            $target = $name
            break
        }
    }
}

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

$tmp = "$slotsFile.tmp"
$reg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $slotsFile -Force

Log "claimed $target topic=$($slotRef.topic) thread=$ThreadId hwnd=$($window.hwnd) pid=$($window.pid) title='$($window.title)'"
Write-Host "[OK] claimed $target -> $($slotRef.topic)"
Write-Host "thread=$ThreadId"
Write-Host "hwnd=$($window.hwnd)"
