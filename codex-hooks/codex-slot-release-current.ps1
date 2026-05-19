param(
    [switch]$FromHook,
    [string]$ThreadId
)

$ErrorActionPreference = "Stop"

$slotsFile = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
$logFile = "$env:USERPROFILE\.codex\hooks\codex-slot-claim-current.log"

function Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $logFile -Value "[$ts] [RELEASE] $Message" -Encoding UTF8
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

if (-not $ThreadId) {
    $ThreadId = $env:CODEX_THREAD_ID
}

if (-not $ThreadId) {
    Log "no thread id, nothing released"
    exit 0
}

if (-not (Test-Path -LiteralPath $slotsFile)) {
    Log "slots file missing: $slotsFile"
    exit 0
}

$reg = Get-Content -LiteralPath $slotsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$released = @()
foreach ($name in "slot-1","slot-2","slot-3","slot-4","slot-5","slot-6","slot-7","slot-8","slot-9") {
    $slotObj = $reg.slots.$name
    if ($slotObj.session_id -eq $ThreadId) {
        $released += $name
        $slotObj.hwnd = $null
        $slotObj.pid = $null
        $slotObj.session_id = $null
        $slotObj.claimed_at = $null
        $slotObj.label = $null
    }
}

if ($released.Count -gt 0) {
    $tmp = "$slotsFile.tmp"
    $reg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $slotsFile -Force
}

Log "released=$($released -join ',') thread=$ThreadId"
