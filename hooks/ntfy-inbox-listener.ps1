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
$Topic        = '${NTFY_LEGACY_TOPIC},${NTFY_TOPIC_PREFIX}-1,${NTFY_TOPIC_PREFIX}-2,${NTFY_TOPIC_PREFIX}-3,${NTFY_TOPIC_PREFIX}-4,${NTFY_TOPIC_PREFIX}-5,${NTFY_TOPIC_PREFIX}-6,${NTFY_TOPIC_PREFIX}-7,${NTFY_TOPIC_PREFIX}-8,${NTFY_TOPIC_PREFIX}-9'
$OutboxTopic  = '${NTFY_LEGACY_TOPIC}'   # legacy / Claude completion pushes / default ingest
$DefaultSlot  = 'slot-1'  # messages on $OutboxTopic (no slot info) route to this default slot
$Server       = '${NTFY_SERVER_URL}'
$Token        = '${NTFY_TOKEN}'
$LogPath      = '$env:USERPROFILE\.claude\hooks\ntfy-inbox-debug.txt'
$PollInterval = 1   # aggressive polling: worst-case 1s latency, avg ~0.5s

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

Log 'listener started (fast-poll 1s mode)'

# Aggressive 1-second polling: worst-case latency 1s, avg ~0.5s.
# SSE was attempted but PS 5.1 StreamReader.ReadLine() doesn't flush curl --no-buffer
# lines reliably on Windows. Fast polling is simpler and meets the latency goal.
$since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

while ($true) {
    try {
        $url = '{0}/{1}/json?poll=1&since={2}' -f $Server, $Topic, $since
        $resp = curl.exe -s -m 10 -H ('Authorization: Bearer ' + $Token) $url 2>$null
        if ($LASTEXITCODE -eq 0 -and $resp) {
            foreach ($line in ($resp -split "`n")) {
                $line = $line.Trim()
                if (-not $line) { continue }
                $msg = $null
                try { $msg = $line | ConvertFrom-Json } catch { continue }
                if (-not $msg) { continue }
                if ($msg.event -ne 'message') { continue }
                if ($msg.time -le $since) { continue }
                $since = $msg.time
                $mid   = $msg.id
                # Defensive: skip anything carrying a title (Claude's auto-pushes)
                if ($msg.title) {
                    Log ('skip titled id=' + $mid + ' title=' + $msg.title)
                    continue
                }
                $text = $msg.message
                $mlen = $text.Length
                # Derive slot id from topic. Legacy outbox topic → DefaultSlot.
                $slotId = ''
                if ($msg.topic -match '${NTFY_TOPIC_PREFIX}-(\d+)') {
                    $slotId = 'slot-' + $Matches[1]
                } elseif ($msg.topic -eq $OutboxTopic) {
                    $slotId = $DefaultSlot
                }
                Log ('user msg id=' + $mid + ' topic=' + $msg.topic + ' slot=' + $slotId + ' len=' + $mlen)

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
        }
    } catch {
        Log ('poll exception: ' + $_.ToString())
    }
    Start-Sleep $PollInterval
}
