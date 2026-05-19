# Watchdog wrapper: runs ntfy listener forever, restarts on crash.
# Started via Startup folder shortcut at login. Survives listener crashes.

$ErrorActionPreference = 'SilentlyContinue'
$wdLog = "$env:USERPROFILE\.claude\hooks\ntfy-listener-watchdog.log"

function WLog { param([string]$m) Add-Content -Path $wdLog -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $m) -Encoding UTF8 }

WLog "watchdog started"

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
