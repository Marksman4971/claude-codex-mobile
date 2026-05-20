# ntfy slot release — free up the slot a cc session was using.
# Works as:
#   1) SessionEnd hook (cc auto-releases on exit), OR
#   2) Manual invocation (e.g. cc crashed, slot leaked, free it).
#
# Release strategy:
#   - If stdin has hook payload with session_id, release the slot bound to that session_id
#   - Else, release any slot whose hwnd corresponds to a dead process

param([switch]$FromHook)
$ErrorActionPreference = 'Stop'

$slotsFile = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
$logFile   = "$env:USERPROFILE\.claude\hooks\ntfy-slot.log"

function Log {
    param([string]$m)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "[$ts] [RELEASE] $m" -Encoding UTF8
}

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

$reg = Get-Content -Raw -Encoding UTF8 $slotsFile | ConvertFrom-Json
$released = @()

foreach ($name in 'slot-1','slot-2','slot-3','slot-4','slot-5','slot-6','slot-7','slot-8','slot-9','slot-10','slot-11','slot-12','slot-13','slot-14','slot-15','slot-16','slot-17','slot-18','slot-19','slot-20') {
    $slot = $reg.slots.$name
    if (-not $slot.hwnd) { continue }

    $shouldRelease = $false
    if ($sessionId -and $slot.session_id -eq $sessionId) {
        $shouldRelease = $true
        Log "$name session_id matches, releasing"
    } else {
        # No session_id given (manual cleanup): check if PID is dead OR HWND is dead
        $alive = $false
        try {
            $p = Get-Process -Id $slot.pid -ErrorAction Stop
            # Process exists, also check HWND still valid
            if ($p.MainWindowHandle -eq [IntPtr]$slot.hwnd) { $alive = $true }
        } catch { }
        if (-not $alive -and -not $sessionId) {
            $shouldRelease = $true
            Log "$name pid=$($slot.pid) dead, releasing stale"
        }
    }

    if ($shouldRelease) {
        $released += $name
        $slot.hwnd = $null
        $slot.pid  = $null
        $slot.session_id = $null
        $slot.claimed_at = $null
        $slot.label = $null
    }
}

if ($released.Count -eq 0) {
    Log "nothing to release (session_id=$sessionId)"
    Write-Host "[INFO] nothing released" -ForegroundColor Yellow
    exit 0
}

$tmp = "$slotsFile.tmp"
$reg | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
Move-Item -Path $tmp -Destination $slotsFile -Force

Log "released: $($released -join ',')"
Write-Host "[OK] released: $($released -join ',')" -ForegroundColor Green
