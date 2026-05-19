$ErrorActionPreference = 'SilentlyContinue'

$logPath = "$env:USERPROFILE\.claude\hooks\ntfy-stop.log"
function Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logPath -Value "[$ts] $msg" -Encoding UTF8
}

$preview = $null
$reason = ''
$sessionId = $null
try {
    $ms = New-Object System.IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($ms)
    $stdin = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    Log "stdin_len=$($stdin.Length)"

    if (-not $stdin) { $reason = 'no_stdin' }
    else {
        $hook = $stdin | ConvertFrom-Json
        $text = $hook.last_assistant_message
        $sessionId = $hook.session_id

        if (-not $text -and $hook.transcript_path -and (Test-Path $hook.transcript_path)) {
            $lines = Get-Content $hook.transcript_path -Encoding UTF8 -Tail 50
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                $entry = $lines[$i] | ConvertFrom-Json
                if ($entry -and $entry.type -eq 'assistant' -and $entry.message.content) {
                    foreach ($block in $entry.message.content) {
                        if ($block.type -eq 'text' -and $block.text) { $text = $block.text; break }
                    }
                    if ($text) { break }
                }
            }
        }

        if (-not $text) { $reason = 'no_text' }
        else {
            $clean = $text
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
            #    so the phone shows real numbers instead of meaningless dashes.
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
                # Blank line → reset bullet counter
                if ($stripped.Trim() -eq '') { $bulletCounter = 0 }
                else { $bulletCounter = 0 }  # non-list line also resets
                [void]$tmpLines.Add($stripped)
            }
            $clean = ($tmpLines -join "`n") -replace '(\r?\n){3,}', "`n`n"
            $preview = $clean.Trim()
            Log "preview_len=$($preview.Length) preview=$preview"
        }
    }
} catch {
    $reason = "exception: $_"
}

if (-not $preview) {
    Log "skip send: $reason"
    return
}

# Look up which slot this session belongs to → push to that slot's topic
# so 同一个 cc 的入和出都走同一个聊天框
$targetTopic = '${NTFY_LEGACY_TOPIC}'  # default fallback (legacy outbox)
if ($sessionId) {
    try {
        $slotsFile = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
        if (Test-Path $slotsFile) {
            $bytes = [System.IO.File]::ReadAllBytes($slotsFile)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) { $bytes = $bytes[3..($bytes.Length-1)] }
            $reg = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
            foreach ($n in 'slot-1','slot-2','slot-3','slot-4','slot-5','slot-6','slot-7','slot-8','slot-9') {
                if ($reg.slots.$n.session_id -eq $sessionId) {
                    $targetTopic = $reg.slots.$n.topic
                    Log "matched session to $n -> $targetTopic"
                    break
                }
            }
        }
    } catch { Log "slot lookup failed: $_" }
}
if ($targetTopic -eq '${NTFY_LEGACY_TOPIC}') { Log "no slot match, using default outbox topic" }

try {
    $body = [System.Text.Encoding]::UTF8.GetBytes($preview)
    Invoke-RestMethod `
        -Uri ('${NTFY_SERVER_URL}/' + $targetTopic) `
        -Method Post `
        -Body $body `
        -ContentType 'text/plain; charset=utf-8' `
        -Headers @{
            'Title' = 'Claude Code'
            'Tags'  = 'robot'
            'Priority' = 'max'
            'Authorization' = 'Bearer ${NTFY_TOKEN}'
        } `
        -TimeoutSec 10 | Out-Null
    Log "sent ok to $targetTopic"
} catch {
    Log "send failed: $_"
}
