# ntfy-slot-gc.ps1 鈥?periodic dead-slot reaper.
# Called by ntfy-injector.ahk SetTimer 60s.
# For each slot in ntfy-slots.json:
#   - if hwnd set AND IsWindow(hwnd) == false 鈫?clear hwnd/pid/session_id/claimed_at/label
#   - keep topic + last_inject_at fields (topic is permanent, last_inject_at audit-only)
# Atomic write via tmp file + Move-Item.

$ErrorActionPreference = 'SilentlyContinue'

$slotsFile = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
$errLog    = "$env:USERPROFILE\.claude\hooks\ntfy-errors.log"

if (-not (Test-Path $slotsFile)) { exit 0 }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class GcWin { [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd); }
"@ -ErrorAction SilentlyContinue

function Test-LiveHwnd($h) {
    if (-not $h) { return $false }
    try { return [GcWin]::IsWindow([IntPtr][int64]$h) } catch { return $false }
}

function Log-Err($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $errLog -Value "[$ts] [ntfy-slot-gc] [INFO] $msg" -Encoding UTF8
}

try {
    $reg = Get-Content -LiteralPath $slotsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $cleared = @()
    $slotNames = $reg.slots.PSObject.Properties.Name
    foreach ($name in $slotNames) {
        $slot = $reg.slots.$name
        if ($slot.hwnd -and -not (Test-LiveHwnd $slot.hwnd)) {
            $cleared += "$name(hwnd=$($slot.hwnd) was='$($slot.label)')"
            $slot.hwnd = $null
            $slot.pid = $null
            $slot.session_id = $null
            $slot.claimed_at = $null
            $slot.label = $null
            # keep topic + last_inject_at
        }
    }
    if ($cleared.Count -gt 0) {
        $tmp = "$slotsFile.gc.tmp"
        $reg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $slotsFile -Force
        Log-Err "GC swept dead slots: $($cleared -join ', ')"
    }
} catch {
    Log-Err "GC failed (non-fatal): $($_.Exception.Message)"
}
