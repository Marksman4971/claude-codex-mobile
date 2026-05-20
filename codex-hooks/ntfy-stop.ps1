param(
    [switch]$DryRun
)

$ErrorActionPreference = "SilentlyContinue"

$logPath = "$env:USERPROFILE\.codex\hooks\ntfy-stop.log"
$slotsFile = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
$defaultTopic = "${NTFY_LEGACY_TOPIC}"
$serverBase = "${NTFY_SERVER_URL}"

function Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $logPath -Value "[$ts] $Message" -Encoding UTF8
}

function Get-HookValue {
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

function Get-TranscriptAssistantText {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -Tail 80
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $entry = $lines[$i] | ConvertFrom-Json
            if (-not $entry) { continue }

            $content = $entry.message.content
            if ($entry.type -eq "assistant" -and $content) {
                foreach ($block in $content) {
                    if ($block.type -eq "text" -and $block.text) {
                        return [string]$block.text
                    }
                }
            }
        }
    } catch {
        Log "transcript fallback failed: $($_.Exception.Message)"
    }

    return $null
}

function ConvertTo-PlainText {
    param([string]$Text)

    $clean = $Text
    # Strip markdown surface tokens
    $clean = $clean -replace '```[a-zA-Z0-9_+-]*\r?\n', '' -replace '```', ''
    $clean = $clean -replace '!\[([^\]]*)\]\([^\)]+\)', '$1'
    $clean = $clean -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
    $clean = $clean -replace '\*\*([^*]+)\*\*', '$1'
    $clean = $clean -replace '(?<!\*)\*([^*\r\n]+)\*(?!\*)', '$1'
    $clean = $clean -replace '`([^`]+)`', '$1'
    $clean = $clean -replace '(?m)^#{1,6}\s+', ''
    $clean = $clean -replace '(?m)^>\s+', ''
    $clean = $clean -replace '~~([^~]+)~~', '$1'
    $clean = $clean -replace '(?m)^[-*_]{3,}\s*$', ''

    # Phone-friendly layout rewrite (2026-05-19):
    # 1. Convert unordered bullets (- / * / +) to numbered list (1. 2. 3.)
    # 2. Tables: drop separator row (|---|---|), trim outer pipes, normalize inner pipes
    # 3. Collapse 3+ consecutive blank lines to a single blank line
    $rawLines = $clean -split "`n"
    $tmpLines = New-Object System.Collections.ArrayList
    $bulletCounter = 0
    foreach ($ln in $rawLines) {
        $stripped = $ln -replace '\r$', ''
        # Table separator row → drop
        if ($stripped.Trim() -match '^\|[\s\-:|]+\|$') { continue }
        # Table data row → trim outer pipes + normalize inner
        if ($stripped.Trim() -match '^\|.*\|$') {
            $cells = $stripped.Trim() -replace '^\|\s*', '' -replace '\s*\|$', ''
            $cells = $cells -replace '\s*\|\s*', ' | '
            [void]$tmpLines.Add($cells)
            continue
        }
        # Unordered bullet → numbered
        if ($stripped -match '^\s*[-*+]\s+(.+)$') {
            $bulletCounter++
            [void]$tmpLines.Add("$bulletCounter. $($Matches[1])")
            continue
        }
        # Reset bullet counter on blank or non-list line
        $bulletCounter = 0
        [void]$tmpLines.Add($stripped)
    }
    $clean = ($tmpLines -join "`n") -replace '(\r?\n){3,}', "`n`n"
    return $clean.Trim()
}

function Resolve-Topic {
    param([string]$SessionId)

    if (-not $SessionId) {
        Log "no session_id, using default outbox topic"
        return $defaultTopic
    }

    try {
        if (Test-Path -LiteralPath $slotsFile) {
            $reg = Get-Content -LiteralPath $slotsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($name in "slot-1","slot-2","slot-3","slot-4","slot-5","slot-6","slot-7","slot-8","slot-9") {
                $slotProp = $reg.slots.PSObject.Properties[$name]
                if (-not $slotProp) { continue }

                $slot = $slotProp.Value
                if ($slot.session_id -eq $SessionId -and $slot.topic) {
                    Log "matched session to $name -> $($slot.topic)"
                    return [string]$slot.topic
                }
            }
        } else {
            Log "slots file missing: $slotsFile"
        }
    } catch {
        Log "slot lookup failed: $($_.Exception.Message)"
    }

    Log "no slot match, using default outbox topic"
    return $defaultTopic
}

function Resolve-WindowName {
    param([string]$SessionId)
    if (-not $SessionId) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $slotsFile)) { return $null }
        $reg = Get-Content -LiteralPath $slotsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in "slot-1","slot-2","slot-3","slot-4","slot-5","slot-6","slot-7","slot-8","slot-9") {
            $slotProp = $reg.slots.PSObject.Properties[$name]
            if (-not $slotProp) { continue }
            $slot = $slotProp.Value
            if ($slot.session_id -eq $SessionId -and $slot.hwnd) {
                if (-not ('NtfyStopCx.W32' -as [type])) {
                    Add-Type -Namespace NtfyStopCx -Name W32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
'@
                }
                $sb = New-Object System.Text.StringBuilder 512
                [void][NtfyStopCx.W32]::GetWindowText([IntPtr]([int64]$slot.hwnd), $sb, 512)
                $raw = $sb.ToString()
                $raw = $raw -replace '^管理员:\s*', ''
                $raw = $raw -replace '^[⠀-⣿✀-➿☀-⛿\s]+', ''
                $raw = $raw.Trim()
                if ($raw -and $raw.Length -gt 0 -and $raw.Length -le 100) {
                    Log "window title: $raw"
                    return $raw
                }
                return $null
            }
        }
    } catch {
        Log "window name lookup failed: $($_.Exception.Message)"
    }
    return $null
}

$text = $null
$reason = ""
$sessionId = $null

try {
    $ms = New-Object System.IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($ms)
    $stdin = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    Log "stdin_len=$($stdin.Length)"

    if (-not $stdin) {
        $reason = "no_stdin"
    } else {
        $hook = $stdin | ConvertFrom-Json
        if ($hook.stop_hook_active -eq $true) {
            $reason = "stop_hook_active"
        } else {
            $sessionId = Get-HookValue -Object $hook -Names @(
                "session_id",
                "sessionId",
                "conversation_id",
                "conversationId",
                "thread_id",
                "threadId"
            )

            $text = Get-HookValue -Object $hook -Names @(
                "last_assistant_message",
                "lastAssistantMessage",
                "assistant_message",
                "assistantMessage",
                "final_response",
                "finalResponse",
                "message"
            )

            if (-not $text) {
                $transcriptPath = Get-HookValue -Object $hook -Names @("transcript_path", "transcriptPath")
                $text = Get-TranscriptAssistantText -Path $transcriptPath
            }

            if (-not $text) {
                $reason = "no_text"
            }
        }
    }
} catch {
    $reason = "parse_exception"
    Log "parse failed: $($_.Exception.Message)"
}

if (-not $text) {
    Log "skip send: $reason"
    return
}

$clean = ConvertTo-PlainText -Text $text
if (-not $clean) {
    Log "skip send: empty_after_clean"
    return
}

$targetTopic = Resolve-Topic -SessionId $sessionId

if ($targetTopic -eq $defaultTopic -and $sessionId -and -not $DryRun) {
    $claimScript = "$env:USERPROFILE\.codex\hooks\codex-slot-claim-current.ps1"
    if (Test-Path -LiteralPath $claimScript) {
        try {
            Log "auto-claim first available slot for session_id=$sessionId"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $claimScript -ThreadId $sessionId | Out-Null
            $targetTopic = Resolve-Topic -SessionId $sessionId
        } catch {
            Log "auto-claim failed: $($_.Exception.Message)"
        }
    } else {
        Log "auto-claim skipped: missing $claimScript"
    }
}

Log "resolved session_id=$sessionId topic=$targetTopic"

if ($DryRun) {
    Log "dry-run topic=$targetTopic len=$($clean.Length)"
    Write-Host "DRY_RUN topic=$targetTopic len=$($clean.Length)"
    return
}

$windowName = Resolve-WindowName -SessionId $sessionId
$notificationTitle = if ($windowName) { "CX · $windowName" } else { 'CX' }
$titleEncoded = [Uri]::EscapeDataString($notificationTitle)

try {
    $body = [System.Text.Encoding]::UTF8.GetBytes($clean)
    Invoke-RestMethod `
        -Uri ("$serverBase/$targetTopic" + '?title=' + $titleEncoded) `
        -Method Post `
        -Body $body `
        -ContentType "text/plain; charset=utf-8" `
        -Headers @{
            "Tags" = "robot"
            "Priority" = "max"
            "Authorization" = "Bearer ${NTFY_TOKEN}"
        } `
        -TimeoutSec 10 | Out-Null
    Log "sent ok to $targetTopic (title='$notificationTitle') len=$($clean.Length)"
} catch {
    Log "send failed: $($_.Exception.Message)"
}
