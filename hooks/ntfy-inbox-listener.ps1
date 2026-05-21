# ntfy inbox listener: phone -> ntfy -> PC clipboard
# 2026-05-19 v2: robust clipboard via .NET STA thread + retry + verbose polling log.

$ErrorActionPreference = 'SilentlyContinue'

# proxy for vultr (task scheduler does not inherit user profile env)
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
$env:HTTP_PROXY  = 'http://127.0.0.1:7890'

# Force PowerShell to read external command stdout as UTF-8. Without this, curl.exe's
# UTF-8 JSON gets decoded as cp936 (zh-CN console codepage) and Chinese turns into garbage
# before we ever ConvertFrom-Json it.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# 2026-05-19 v3: multi-slot topic pool. Listener subscribes to all 7 slot topics
# (${NTFY_TOPIC_PREFIX}-1 .. ${NTFY_TOPIC_PREFIX}-7) via ntfy's multi-topic syntax `/topic1,topic2,.../json`.
# Outbox topic ${NTFY_LEGACY_TOPIC} kept for Claude completion pushes (one-way PC->phone).
# When a message arrives on slot-N, listener wraps clipboard with marker carrying slot id,
# so AHK injector can route to the correct cc window.
$SlotsFile    = "$env:USERPROFILE\.claude\hooks\ntfy-slots.json"
$LastPushFile = "$env:USERPROFILE\.claude\hooks\ntfy-last-push.json"
$Topic        = '${NTFY_LEGACY_TOPIC},${NTFY_TOPIC_PREFIX}-1,${NTFY_TOPIC_PREFIX}-2,${NTFY_TOPIC_PREFIX}-3,${NTFY_TOPIC_PREFIX}-4,${NTFY_TOPIC_PREFIX}-5,${NTFY_TOPIC_PREFIX}-6,${NTFY_TOPIC_PREFIX}-7,${NTFY_TOPIC_PREFIX}-8,${NTFY_TOPIC_PREFIX}-9,${NTFY_TOPIC_PREFIX}-10,${NTFY_TOPIC_PREFIX}-11,${NTFY_TOPIC_PREFIX}-12,${NTFY_TOPIC_PREFIX}-13,${NTFY_TOPIC_PREFIX}-14,${NTFY_TOPIC_PREFIX}-15,${NTFY_TOPIC_PREFIX}-16,${NTFY_TOPIC_PREFIX}-17,${NTFY_TOPIC_PREFIX}-18,${NTFY_TOPIC_PREFIX}-19,${NTFY_TOPIC_PREFIX}-20'
$OutboxTopic  = '${NTFY_LEGACY_TOPIC}'   # legacy / Claude completion pushes / default ingest
$DefaultSlot  = 'slot-1'  # messages on $OutboxTopic (no slot info) route to this default slot
$Server       = '${NTFY_SERVER_URL}'
$Token        = '${NTFY_TOKEN}'
$LogPath      = '$env:USERPROFILE\.claude\hooks\ntfy-inbox-debug.txt'
$PollInterval = 1   # aggressive polling: worst-case 1s latency, avg ~0.5s
$CodexDispatchScript = "$env:USERPROFILE\.codex\hooks\codex-ntfy-dispatch.ps1"
$CodexInboxDir = "$env:USERPROFILE\.codex\hooks\ntfy-inbox"
$EnableCodexAppServerDispatch = ($env:NTFY_CODEX_APP_SERVER_DISPATCH -eq '1')

# Load Windows.Forms once for Clipboard class
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    Add-Content -Path $LogPath -Value ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] FATAL load forms: ' + $_.ToString()) -Encoding UTF8
    exit 1
}

function Log {
    param([string]$msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogPath -Value ('[' + $ts + '] ' + $msg) -Encoding UTF8
}

function Push-Outbox {
    param([string]$title, [string]$body)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $hdr = @{
            'Title'         = $title
            'Tags'          = 'clipboard'
            'Priority'      = 'default'
            'Authorization' = 'Bearer ' + $Token
        }
        Invoke-RestMethod -Uri ($Server + '/' + $OutboxTopic) -Method Post -Body $bytes -ContentType 'text/plain; charset=utf-8' -Headers $hdr -TimeoutSec 5 | Out-Null
    } catch {
        Log ('outbox push fail: ' + $_.ToString())
    }
}

# v8.1 (2026-05-21): push back to ORIGINAL topic to alert user that the slot was reclaimed.
# Title is URL-encoded into the URI (not a header) because HTTP headers can't carry UTF-8 / control chars.
function Push-StaleReplyWarning {
    param([string]$topic, [string]$origSid, [string]$currentSid, [string]$replyText)
    try {
        $preview = if ($replyText.Length -gt 80) { $replyText.Substring(0, 80) + '...' } else { $replyText }
        $shortOrig = if ($origSid) { $origSid.Substring(0, [Math]::Min(8, $origSid.Length)) } else { 'none' }
        $shortNew  = if ($currentSid) { $currentSid.Substring(0, [Math]::Min(8, $currentSid.Length)) } else { 'none' }
        $bodyTxt = "目标窗口已换主：原发送窗口 sid=$shortOrig 已不存在，当前 slot 归属新会话 sid=$shortNew。这条回复未注入，请改发到新窗口。`n`n被拦截的回复：`n$preview"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyTxt)
        $title = 'Stale notification - 回复未注入'
        $titleEncoded = [Uri]::EscapeDataString($title)
        $hdr = @{
            'Tags'          = 'warning'
            'Priority'      = 'high'
            'Authorization' = 'Bearer ' + $Token
        }
        Invoke-RestMethod -Uri ($Server + '/' + $topic + '?title=' + $titleEncoded) -Method Post -Body $bytes -ContentType 'text/plain; charset=utf-8' -Headers $hdr -TimeoutSec 5 | Out-Null
        Log ('stale-reply warning pushed to ' + $topic + ' (orig sid=' + $shortOrig + ' vs current=' + $shortNew + ')')
    } catch {
        Log ('stale-reply warning push fail: ' + $_.ToString())
    }
}

function Get-LastPushSession {
    param([string]$slotId)
    if (-not (Test-Path $LastPushFile)) { return $null }
    try {
        $bz = [System.IO.File]::ReadAllBytes($LastPushFile)
        if ($bz.Length -ge 3 -and $bz[0] -eq 0xEF) { $bz = $bz[3..($bz.Length-1)] }
        $txt = [System.Text.Encoding]::UTF8.GetString($bz)
        if (-not $txt) { return $null }
        $reg = $txt | ConvertFrom-Json
        return $reg.$slotId.session_id
    } catch {
        Log ('last_push read fail (non-fatal): ' + $_.ToString())
        return $null
    }
}

function Get-CurrentSlotSession {
    param([string]$slotId)
    if (-not (Test-Path $SlotsFile)) { return $null }
    try {
        $bz = [System.IO.File]::ReadAllBytes($SlotsFile)
        if ($bz.Length -ge 3 -and $bz[0] -eq 0xEF) { $bz = $bz[3..($bz.Length-1)] }
        $txt = [System.Text.Encoding]::UTF8.GetString($bz)
        if (-not $txt) { return $null }
        $reg = $txt | ConvertFrom-Json
        return $reg.slots.$slotId.session_id
    } catch {
        Log ('slots read fail (non-fatal): ' + $_.ToString())
        return $null
    }
}

function Show-ClipToast {
    param([string]$text)
    try {
        $preview = if ($text.Length -gt 200) { $text.Substring(0, 200) + '...' } else { $text }
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Information
        # Windows NotifyIcon balloon requires non-empty title, otherwise nothing shows.
        # Use a single space so visually it's "title-less".
        $icon.BalloonTipTitle = ' '
        $icon.BalloonTipText  = $preview
        $icon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Info
        $icon.Visible = $true
        $icon.ShowBalloonTip(4000)
        Start-Sleep -Milliseconds 300
        $icon.Dispose()
    } catch {
        Log ('toast fail: ' + $_.ToString())
    }
}

function Set-ClipRobust {
    param([string]$text)
    # Verify accepts any version that ends with our message tail (AHK might have
    # stripped any of: ⌬⌬NTFY-slot-N⌬⌬ prefix). Only retry on hard exception.
    $bz = [char]0x232C
    $markerRegex = "$bz$bz`NTFY(-slot-\d+)?$bz$bz"
    $clean = $text -replace $markerRegex, ''
    for ($i = 1; $i -le 3; $i++) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($text)
            Start-Sleep -Milliseconds 150
            $rb = [System.Windows.Forms.Clipboard]::GetText()
            if ($rb -eq $text -or $rb -eq $clean) { return $true }
            Log ('  clip attempt ' + $i + ' mismatch (got: ' + $rb.Substring(0,[Math]::Min(30,$rb.Length)) + ')')
        } catch {
            Log ('  clip attempt ' + $i + ' exception: ' + $_.ToString())
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Queue-CodexInbound {
    param([string]$slotId, [string]$messageId, [string]$topic, [string]$text)

    # Disabled by default: app-server turns do run, but they are not surfaced in
    # the active Codex Desktop window. Keep this path opt-in only until there is
    # a verified foreground handoff.
    if (-not $EnableCodexAppServerDispatch) { return $false }

    if (-not $slotId -or -not (Test-Path $SlotsFile)) { return $false }
    try {
        $reg = Get-Content -LiteralPath $SlotsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $slot = $reg.slots.$slotId
        if (-not $slot) { return $false }
        if ($slot.label -notlike 'Codex Desktop*') { return $false }
        if (-not $slot.session_id) {
            Log ('codex dispatch unavailable: missing session_id for ' + $slotId)
            return $false
        }
        if (-not (Test-Path -LiteralPath $CodexDispatchScript)) {
            Log ('codex dispatch unavailable: missing ' + $CodexDispatchScript)
            return $false
        }

        New-Item -ItemType Directory -Path $CodexInboxDir -Force | Out-Null
        $safeId = ($messageId -replace '[^A-Za-z0-9_.-]', '_')
        $file = Join-Path $CodexInboxDir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $slotId + '-' + $safeId + '.json')
        [PSCustomObject]@{
            id = $messageId
            topic = $topic
            slot = $slotId
            threadId = [string]$slot.session_id
            text = $text
            receivedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8

        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $CodexDispatchScript,
            '-MessageFile', $file
        ) | Out-Null
        Log ('codex dispatch queued id=' + $messageId + ' slot=' + $slotId + ' thread=' + $slot.session_id)
        return $true
    } catch {
        Log ('codex dispatch queue failed id=' + $messageId + ': ' + $_.ToString())
        return $false
    }
}

Log 'listener started (fast-poll 1s mode)'

# Aggressive 1-second polling: worst-case latency 1s, avg ~0.5s.
# SSE was attempted but PS 5.1 StreamReader.ReadLine() doesn't flush curl --no-buffer
# lines reliably on Windows. Fast polling is simpler and meets the latency goal.
$since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$SeenIds = @{}

while ($true) {
    try {
        $url = '{0}/{1}/json?poll=1&since={2}' -f $Server, $Topic, $since
        $resp = curl.exe -s -m 10 -H ('Authorization: Bearer ' + $Token) $url 2>$null
        if ($LASTEXITCODE -eq 0 -and $resp) {
            $maxTime = [int64]$since
            foreach ($line in ($resp -split "`n")) {
                $line = $line.Trim()
                if (-not $line) { continue }
                $msg = $null
                try { $msg = $line | ConvertFrom-Json } catch { continue }
                if (-not $msg) { continue }
                if ($msg.event -ne 'message') { continue }
                $mid   = $msg.id
                if ($SeenIds.ContainsKey($mid)) { continue }
                $SeenIds[$mid] = $true
                if ([int64]$msg.time -gt $maxTime) { $maxTime = [int64]$msg.time }
                # Defensive: skip anything carrying a title (Claude's auto-pushes)
                if ($msg.title) {
                    Log ('skip titled id=' + $mid + ' title=' + $msg.title)
                    continue
                }
                $text = $msg.message
                $mlen = $text.Length
                # Derive slot id from topic. Legacy outbox topic → REFUSE (v8.4, 2026-05-21).
                # Old behaviour silently routed outbox replies to DefaultSlot=slot-1, but slot-1's
                # window is often whatever happened to claim it (Codex Desktop, an old cc, etc.) —
                # this caused phone replies meant for one cc to land in a totally unrelated window.
                # New behaviour: refuse, push warning back to outbox so user knows their reply
                # didn't go anywhere. cc Stop hook v8.4 auto-claims a fresh slot so future Stop
                # notifications carry slot-N topic instead of outbox.
                $slotId = ''
                if ($msg.topic -match '${NTFY_TOPIC_PREFIX}-(\d+)') {
                    $slotId = 'slot-' + $Matches[1]
                } elseif ($msg.topic -eq $OutboxTopic) {
                    $preview2 = if ($mclean.Length -gt 80) { $mclean.Substring(0, 80) + '...' } else { $mclean }
                    Log ('REFUSE outbox reply (no slot info, would misroute): ' + $preview2)
                    Push-StaleReplyWarning -topic $OutboxTopic -origSid 'outbox-default' -currentSid 'unknown' -replyText ("无法路由：你回复的通知走的是 outbox 默认 topic（不带 slot 编号）。原 cc 没有绑定 slot，无法确定目标窗口。请订阅 cc 自己的 ${NTFY_TOPIC_PREFIX}-N topic 后再回复。`n`n原回复：`n" + $mclean)
                    continue  # skip clip + AHK inject
                }
                Log ('user msg id=' + $mid + ' topic=' + $msg.topic + ' slot=' + $slotId + ' len=' + $mlen)

                # v8.1 (2026-05-21): stale-notification gate.
                # If user replied to an old phone notification but the slot has since been reclaimed
                # by a different session, the reply would land in the wrong window. Detect this by
                # comparing last_push[slot].session_id (whoever last pushed Stop notif from this slot)
                # against slots.json[slot].session_id (whoever owns the slot right now).
                # Mismatch → reject + push warning back to the topic so user knows.
                if ($slotId -and $slotId -match '^slot-\d+$') {
                    $lastPushSid = Get-LastPushSession -slotId $slotId
                    $currentSid  = Get-CurrentSlotSession -slotId $slotId
                    if ($lastPushSid -and $currentSid -and $lastPushSid -ne $currentSid) {
                        Log ('STALE reply: slot=' + $slotId + ' last_push_sid=' + $lastPushSid.Substring(0,8) + ' current_sid=' + $currentSid.Substring(0,8) + ' — rejecting inject')
                        Push-StaleReplyWarning -topic $msg.topic -origSid $lastPushSid -currentSid $currentSid -replyText $text
                        continue
                    }
                }

                # Optional experimental Codex app-server route. Default is off
                # because app-server turns complete in the background and do not
                # surface in the active Codex Desktop window.
                if (Queue-CodexInbound -slotId $slotId -messageId $mid -topic $msg.topic -text $text) {
                    Show-ClipToast ('[Codex queued] ' + $text)
                    continue
                }

                # Wrap with NTFY-{slot} marker so AHK injector routes to correct window
                # Format: ⌬⌬NTFY-{slotId}⌬⌬{message}
                $bz = [char]0x232C
                $wrapped = $bz + $bz + 'NTFY-' + $slotId + $bz + $bz + $text
                $ok = Set-ClipRobust $wrapped
                if ($ok) {
                    Log ('clip OK (slot=' + $slotId + '): ' + $text.Substring(0, [Math]::Min(60, $mlen)))
                    Show-ClipToast $text
                } else {
                    Log ('clip FAILED id=' + $mid)
                }
            }
            # Keep a one-second overlap so multiple messages sharing the same ntfy
            # timestamp are not lost. SeenIds handles duplicate cache hits.
            if ($maxTime -gt [int64]$since) { $since = [Math]::Max(0, $maxTime - 1) }
            if ($SeenIds.Count -gt 2000) { $SeenIds.Clear() }
        }
    } catch {
        Log ('poll exception: ' + $_.ToString())
    }
    Start-Sleep $PollInterval
}
