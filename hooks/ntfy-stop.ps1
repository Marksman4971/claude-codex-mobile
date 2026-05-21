$ErrorActionPreference = 'SilentlyContinue'

$logPath = "$env:USERPROFILE\.claude\hooks\ntfy-stop.log"
$errLogPath = "$env:USERPROFILE\.claude\hooks\ntfy-errors.log"
$logMaxBytes = 5MB

# v8.0: rotate log if > 5MB (called once per Stop hook invocation, cheap)
function Rotate-IfLarge($path) {
    if (Test-Path $path) {
        try {
            $size = (Get-Item $path -ErrorAction SilentlyContinue).Length
            if ($size -gt $logMaxBytes) {
                Move-Item -Path $path -Destination "$path.1" -Force
            }
        } catch {}
    }
}
Rotate-IfLarge $logPath
Rotate-IfLarge $errLogPath

function Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logPath -Value "[$ts] $msg" -Encoding UTF8
}

# v8.0: ErrLog tees errors/warnings to centralized ntfy-errors.log for one-glance history
function ErrLog($msg, $severity = 'ERROR') {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logPath -Value "[$ts] $msg" -Encoding UTF8
    Add-Content -Path $errLogPath -Value "[$ts] [ntfy-stop] [$severity] $msg" -Encoding UTF8
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

            # Phone-friendly layout rewrite (2026-05-19, table-unfold 2026-05-20):
            # 1. Convert unordered bullets (- / * / +) to numbered list (1. 2. 3.)
            # 2. Tables → paragraphs:
            #    - separator row (|---|---|) drops AND removes the header row before it
            #    - 2-col row → 'key: value'
            #    - 3+ col row → 'c1 · c2 · c3'  (middle dot, visually lighter than '|')
            # 3. Collapse 3+ consecutive blank lines to one
            $rawLines = $clean -split "`n"
            $tmpLines = New-Object System.Collections.ArrayList
            $bulletCounter = 0
            foreach ($ln in $rawLines) {
                $stripped = $ln -replace '\r$', ''
                # Table separator row → drop, AND remove the header line just added before it
                if ($stripped.Trim() -match '^\|[\s\-:|]+\|$') {
                    if ($tmpLines.Count -gt 0) { $tmpLines.RemoveAt($tmpLines.Count - 1) }
                    continue
                }
                # Table data row → split cells, format by column count
                if ($stripped.Trim() -match '^\|(.*)\|$') {
                    $cells = ($Matches[1] -split '\s*\|\s*') | ForEach-Object { $_.Trim() }
                    if ($cells.Count -eq 2) {
                        [void]$tmpLines.Add("$($cells[0]): $($cells[1])")
                    } elseif ($cells.Count -ge 3) {
                        [void]$tmpLines.Add(($cells -join ' · '))
                    } elseif ($cells.Count -eq 1 -and $cells[0]) {
                        [void]$tmpLines.Add($cells[0])
                    }
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
# Also extract the WT window title (set by /rename) for the phone notification title
$targetTopic = '${NTFY_LEGACY_TOPIC}'  # default fallback (legacy outbox)
$windowName = $null
if ($sessionId) {
    try {
        $slotsFile = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
        if (Test-Path $slotsFile) {
            $bytes = [System.IO.File]::ReadAllBytes($slotsFile)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) { $bytes = $bytes[3..($bytes.Length-1)] }
            $reg = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
            foreach ($n in 'slot-1','slot-2','slot-3','slot-4','slot-5','slot-6','slot-7','slot-8','slot-9','slot-10','slot-11','slot-12','slot-13','slot-14','slot-15','slot-16','slot-17','slot-18','slot-19','slot-20') {
                if ($reg.slots.$n.session_id -eq $sessionId) {
                    $targetTopic = $reg.slots.$n.topic
                    Log "matched session to $n -> $targetTopic"
                    # Derive window title from HWND for notification title
                    if ($reg.slots.$n.hwnd) {
                        if (-not ('NtfyStop.W32' -as [type])) {
                            Add-Type -Namespace NtfyStop -Name W32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
'@
                        }
                        $sb = New-Object System.Text.StringBuilder 512
                        [void][NtfyStop.W32]::GetWindowText([IntPtr]([int64]$reg.slots.$n.hwnd), $sb, 512)
                        $raw = $sb.ToString()
                        # Strip admin prefix + spinner/braille/dingbats/misc symbols
                        $raw = $raw -replace '^管理员:\s*', ''
                        $raw = $raw -replace '^[⠀-⣿✀-➿☀-⛿\s]+', ''
                        $raw = $raw.Trim()
                        if ($raw -and $raw.Length -gt 0 -and $raw.Length -le 100) {
                            $windowName = $raw
                            Log "window title: $windowName"
                        }
                    }
                    break
                }
            }
        }
    } catch { Log "slot lookup failed: $_" }
}
if ($targetTopic -eq '${NTFY_LEGACY_TOPIC}') {
    Log "no slot match, attempting auto-claim a free slot (v8.4 — instead of fall through outbox)"
    if ($sessionId) {
        try {
            $bytesAc = [System.IO.File]::ReadAllBytes($slotsFile)
            if ($bytesAc.Length -ge 3 -and $bytesAc[0] -eq 0xEF) { $bytesAc = $bytesAc[3..($bytesAc.Length-1)] }
            $regAc = [System.Text.Encoding]::UTF8.GetString($bytesAc) | ConvertFrom-Json
            $claimed = $null
            foreach ($n in 'slot-1','slot-2','slot-3','slot-4','slot-5','slot-6','slot-7','slot-8','slot-9','slot-10','slot-11','slot-12','slot-13','slot-14','slot-15','slot-16','slot-17','slot-18','slot-19','slot-20') {
                $s = $regAc.slots.$n
                if (-not $s.hwnd -and -not $s.session_id) {
                    $s.session_id = $sessionId
                    $s.claimed_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    $s.label = "cc Stop-hook auto-claim (no hwnd — SessionStart didn't fire)"
                    $claimed = $n
                    break
                }
            }
            if ($claimed) {
                $tmpAc = "$slotsFile.tmp"
                $regAc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmpAc -Encoding UTF8
                Move-Item -LiteralPath $tmpAc -Destination $slotsFile -Force
                $targetTopic = $regAc.slots.$claimed.topic
                Log "auto-claimed $claimed -> $targetTopic for session_id=$sessionId"
            } else {
                Log "auto-claim failed: no free slot (all 20 occupied) — falling back to outbox"
            }
        } catch {
            Log "auto-claim error: $_ — falling back to outbox"
        }
    }
}
if ($targetTopic -eq '${NTFY_LEGACY_TOPIC}') { Log "[WARN] still on default outbox topic — phone reply will be misrouted; consider /gen-ntfy fix or open new cc" }

$notificationTitle = if ($windowName) { "CC · $windowName" } else { 'CC' }
# URL-encode title because HTTP headers don't reliably carry UTF-8 / Chinese chars
$titleEncoded = [Uri]::EscapeDataString($notificationTitle)

$body = [System.Text.Encoding]::UTF8.GetBytes($preview)
$maxAttempts = 3
$attempt = 0
$sent = $false
while (-not $sent -and $attempt -lt $maxAttempts) {
    $attempt++
    try {
        Invoke-RestMethod `
            -Uri ('${NTFY_SERVER_URL}/' + $targetTopic + '?title=' + $titleEncoded) `
            -Method Post `
            -Body $body `
            -ContentType 'text/plain; charset=utf-8' `
            -Headers @{
                'Tags'  = 'robot'
                'Priority' = 'max'
                'Authorization' = 'Bearer ${NTFY_TOKEN}'
            } `
            -TimeoutSec 10 | Out-Null
        Log "sent ok to $targetTopic (title='$notificationTitle') attempt=$attempt"
        $sent = $true

        # v8.1 (2026-05-21): write last_push sidecar so listener can detect stale-notification-reply.
        # When user replies to an old notification on phone but slot has been reclaimed since,
        # listener compares last_push[slot].session_id vs current slot.session_id; mismatch → reject + warn.
        if ($sessionId -and $targetTopic -match '${NTFY_TOPIC_PREFIX}-(\d+)$') {
            $slotKey = 'slot-' + $Matches[1]
            $lastPushFile = "$env:USERPROFILE\.claude\hooks\ntfy-last-push.json"
            try {
                $reg = [ordered]@{}
                if (Test-Path $lastPushFile) {
                    $bz = [System.IO.File]::ReadAllBytes($lastPushFile)
                    if ($bz.Length -ge 3 -and $bz[0] -eq 0xEF) { $bz = $bz[3..($bz.Length-1)] }
                    $txt = [System.Text.Encoding]::UTF8.GetString($bz)
                    if ($txt) {
                        $existing = $txt | ConvertFrom-Json
                        foreach ($p in $existing.PSObject.Properties) { $reg[$p.Name] = $p.Value }
                    }
                }
                $reg[$slotKey] = [PSCustomObject]@{
                    session_id = $sessionId
                    pushed_at  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    title      = $notificationTitle
                }
                ($reg | ConvertTo-Json -Depth 4) | Out-File -FilePath $lastPushFile -Encoding UTF8 -Force
                Log "last_push updated: $slotKey -> sid=$($sessionId.Substring(0,[Math]::Min(8,$sessionId.Length)))"
            } catch {
                Log "last_push update failed (non-fatal): $_"
            }
        }
    } catch {
        $errMsg = $_.Exception.Message
        $statusCode = $null
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        # Retry only on transient errors: 429 (rate limit) / 5xx (gateway/server)
        $retryable = ($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -lt 600) -or ($null -eq $statusCode)
        if ($attempt -lt $maxAttempts -and $retryable) {
            ErrLog "send attempt=$attempt failed (status=$statusCode): $errMsg — retrying in 1.5s" 'WARN'
            Start-Sleep -Milliseconds 1500
        } else {
            ErrLog "send failed permanently after $attempt attempts (status=$statusCode): $errMsg" 'ERROR'
            break
        }
    }
}
