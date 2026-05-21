# Watchdog wrapper: runs ntfy listener forever, restarts on crash.
# Started via NtfyListenerWatchdog Scheduled Task (sole authority since 2026-05-21).
# Survives listener crashes.

$ErrorActionPreference = 'SilentlyContinue'
$wdLog = "$env:USERPROFILE\.claude\hooks\ntfy-listener-watchdog.log"

function WLog { param([string]$m) Add-Content -Path $wdLog -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $m) -Encoding UTF8 }

# v8.1 (2026-05-21): singleton enforcement. Task Scheduler's MultipleInstances=IgnoreNew can
# still race with RestartCount-on-failure events, producing 2+ wrapper instances that then
# fight each other's children (kill loop). Wrapper-side singleton kills all other wrapper
# instances on startup, leaving only the most recent one alive. Cycle terminates because
# Task Scheduler with IgnoreNew won't queue more.
$myPid = $PID
$otherWrappers = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*run-ntfy-listener*' -and $_.ProcessId -ne $myPid }
if ($otherWrappers) {
    foreach ($w in $otherWrappers) {
        WLog ("singleton: killing prior wrapper PID=" + $w.ProcessId)
        try { Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 500
}

WLog "watchdog started (singleton enforced)"

while ($true) {
    # Kill any stray listener procs (single-instance enforcement)
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*ntfy-inbox-listener*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    WLog "spawning listener"
    try {
        # Inline run — when listener exits/crashes, wrapper loop iterates
        & 'powershell.exe' -NoProfile -Sta -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\hooks\ntfy-inbox-listener.ps1"
        WLog "listener exited with code $LASTEXITCODE, restarting in 5s"
    } catch {
        WLog ("listener exception: " + $_.ToString())
    }
    Start-Sleep -Seconds 5
}
