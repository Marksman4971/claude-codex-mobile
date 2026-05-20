# ntfy-mark-inject.ps1 — atomically update last_inject_at on a slot.
# Called by ntfy-injector.ahk after a successful Tier 3b inject so the next
# Codex Stop hook can prefer this slot for its response routing (instead of
# falling back to GetForegroundWindow which depends on where the user is looking).

param(
    [Parameter(Mandatory=$true)][string]$SlotId
)

$ErrorActionPreference = 'SilentlyContinue'

$slotsFile = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
if (-not (Test-Path -LiteralPath $slotsFile)) { exit 0 }

try {
    $reg = Get-Content -LiteralPath $slotsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $slotProp = $reg.slots.PSObject.Properties[$SlotId]
    if (-not $slotProp) { exit 0 }
    $slot = $slotProp.Value
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ($slot.PSObject.Properties['last_inject_at']) {
        $slot.last_inject_at = $ts
    } else {
        $slot | Add-Member -NotePropertyName last_inject_at -NotePropertyValue $ts -Force
    }
    $tmp = "$slotsFile.tmp.$PID"
    $reg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $slotsFile -Force
} catch {
    # silent — failed marker should not block AHK
}
