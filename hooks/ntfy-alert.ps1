# ntfy-alert.ps1 鈥?push a high-priority warning notification to a topic.
# Used by ntfy-injector.ahk Tier 4 fail-closed path: when AHK cannot locate
# the target [slot-N] cc tab, instead of HWND-blind injection it calls this
# helper to alert the user on their phone (same topic the message arrived on).

param(
    [Parameter(Mandatory=$true)][string]$Topic,
    [Parameter(Mandatory=$true)][string]$Title,
    [Parameter(Mandatory=$true)][string]$Body
)

$ErrorActionPreference = 'SilentlyContinue'

$server = '${NTFY_SERVER}'
$token  = '${NTFY_TOKEN}'

$titleEnc = [Uri]::EscapeDataString($Title)
$uri      = "$server/$Topic`?title=$titleEnc"

try {
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    Invoke-RestMethod -Uri $uri -Method Post -Body $bodyBytes -ContentType 'text/plain; charset=utf-8' `
        -Headers @{ Authorization = "Bearer $token"; Tags = 'warning'; Priority = 'high' } `
        -TimeoutSec 10 | Out-Null
} catch {
    # Silent 鈥?alert push itself failing should not blow up AHK
}

