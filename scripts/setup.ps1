<#
.SYNOPSIS
  claude-codex-mobile setup: deploy hooks + Startup + Claude/Codex integration

.DESCRIPTION
  Reads ../config.ps1 (sourceable PowerShell file with $env:NTFY_* values),
  substitutes ${NAME} placeholders in repo's hooks/ + codex-hooks/ templates,
  and deploys to ~/.claude/hooks/ + ~/.codex/hooks/.

.PARAMETER Stage
  Which stage to run: all / hooks / startup / settings / codex / smoke / verify

.PARAMETER ConfigFile
  Path to filled config.ps1. Default: ../config.ps1 (repo root).

.PARAMETER Force
  Overwrite already-deployed files at target locations.
#>
[CmdletBinding()]
param(
  [ValidateSet('all','hooks','startup','settings','codex','smoke','verify')]
  [string]$Stage = 'verify',
  [string]$ConfigFile,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot       = Split-Path $PSScriptRoot -Parent
$RepoHooks      = Join-Path $RepoRoot 'hooks'
$RepoCodexHooks = Join-Path $RepoRoot 'codex-hooks'
if (-not $ConfigFile) { $ConfigFile = Join-Path $RepoRoot 'config.ps1' }

$TargetHooks    = "$env:USERPROFILE\.claude\hooks"
$TargetLib      = "$TargetHooks\lib"
$TargetCodex    = "$env:USERPROFILE\.codex\hooks"
$StartupDir     = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$SettingsJson   = "$env:USERPROFILE\.claude\settings.json"
$CodexHooksJson = "$env:USERPROFILE\.codex\hooks.json"
$AhkExe         = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

Write-Host ""
Write-Host "===== claude-codex-mobile setup ($Stage) =====" -ForegroundColor Cyan

function Load-Config {
  if (-not (Test-Path $ConfigFile)) {
    Write-Host "[ERR] $ConfigFile not found" -ForegroundColor Red
    Write-Host "      Copy config.example.ps1 to config.ps1 and fill values" -ForegroundColor Yellow
    exit 1
  }
  # Dot-source to populate $env:NTFY_* in current session
  . $ConfigFile
  # Validate required values
  $required = @('NTFY_TOKEN','NTFY_SERVER_URL','NTFY_TOPIC_PREFIX','NTFY_LEGACY_TOPIC','NTFY_USER')
  $missing = @()
  foreach ($n in $required) {
    $v = [Environment]::GetEnvironmentVariable($n, 'Process')
    if (-not $v -or $v -like 'YOUR_*' -or $v -eq 'myhost-cc-slot' -or $v -eq 'myhost-cc-legacy') {
      $missing += $n
    }
  }
  if ($missing.Count -gt 0) {
    Write-Host "[ERR] config.ps1 missing or default values for:" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "  - `$env:$m" -ForegroundColor Red }
    exit 1
  }
}

function Substitute-Placeholders {
  param([string]$Text)
  $vars = @('NTFY_TOKEN','NTFY_SERVER_URL','NTFY_SERVER_HOSTPORT','NTFY_TOPIC_PREFIX','NTFY_LEGACY_TOPIC','NTFY_USER','NTFY_PASSWORD','NTFY_FALLBACK_HOST')
  foreach ($v in $vars) {
    $val = [Environment]::GetEnvironmentVariable($v, 'Process')
    if ($val) { $Text = $Text.Replace('${' + $v + '}', $val) }
  }
  return $Text
}

function Deploy-File {
  param([string]$Src, [string]$Dst, [switch]$Substitute)
  if (-not (Test-Path $Src)) {
    Write-Host "  [SKIP] source missing: $Src" -ForegroundColor DarkGray
    return $false
  }
  if ((Test-Path $Dst) -and -not $Force) {
    Write-Host "  [KEEP] $Dst (use -Force to overwrite)" -ForegroundColor DarkGray
    return $false
  }
  $dstDir = Split-Path $Dst -Parent
  if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
  if ($Substitute) {
    $content = [System.IO.File]::ReadAllText($Src, [System.Text.Encoding]::UTF8)
    $content = Substitute-Placeholders $content
    # Preserve BOM for .ps1
    $enc = if ($Src -like '*.ps1') {
      New-Object System.Text.UTF8Encoding $true
    } else {
      New-Object System.Text.UTF8Encoding $false
    }
    [System.IO.File]::WriteAllText($Dst, $content, $enc)
  } else {
    Copy-Item $Src $Dst -Force
  }
  Write-Host "  [DEPLOY] $Dst" -ForegroundColor Green
  return $true
}

function Stage-Verify {
  Write-Host "[verify] checking deployment status..."
  $checks = [ordered]@{
    'hooks/ntfy-stop.ps1'              = Test-Path "$TargetHooks\ntfy-stop.ps1"
    'hooks/ntfy-inbox-listener.ps1'    = Test-Path "$TargetHooks\ntfy-inbox-listener.ps1"
    'hooks/run-ntfy-listener.ps1'      = Test-Path "$TargetHooks\run-ntfy-listener.ps1"
    'hooks/ntfy-injector.ahk'          = Test-Path "$TargetHooks\ntfy-injector.ahk"
    'hooks/lib/UIA.ahk'                = Test-Path "$TargetLib\UIA.ahk"
    'hooks/ntfy-slot-claim.ps1'        = Test-Path "$TargetHooks\ntfy-slot-claim.ps1"
    'hooks/ntfy-slot-release.ps1'      = Test-Path "$TargetHooks\ntfy-slot-release.ps1"
    'hooks/ntfy-slots.json'            = Test-Path "$TargetHooks\ntfy-slots.json"
    'Startup ntfy-injector.lnk'        = Test-Path "$StartupDir\ntfy-injector.lnk"
    'Startup watchdog.lnk'             = Test-Path "$StartupDir\ntfy-listener-watchdog.lnk"
    'AutoHotkey v2'                    = Test-Path $AhkExe
    'Claude settings.json'             = Test-Path $SettingsJson
    'Codex hooks/ntfy-stop.ps1'        = Test-Path "$TargetCodex\ntfy-stop.ps1"
    'Codex hooks.json'                 = Test-Path $CodexHooksJson
  }
  foreach ($k in $checks.Keys) {
    $tag = if ($checks[$k]) { '[OK]  ' } else { '[MISS]' }
    $color = if ($checks[$k]) { 'Green' } else { 'Red' }
    Write-Host "  $tag $k" -ForegroundColor $color
  }
}

function Stage-Hooks {
  Write-Host "[hooks] deploy hook files (with placeholder substitution)..."
  Load-Config
  # All hook files use ${NAME} placeholders → substitute on deploy
  foreach ($name in @('ntfy-stop.ps1','ntfy-inbox-listener.ps1','run-ntfy-listener.ps1','ntfy-injector.ahk','ntfy-slot-claim.ps1','ntfy-slot-release.ps1')) {
    Deploy-File "$RepoHooks\$name" "$TargetHooks\$name" -Substitute | Out-Null
  }
  # lib/UIA.ahk: no substitution needed
  Deploy-File "$RepoHooks\lib\UIA.ahk" "$TargetLib\UIA.ahk" | Out-Null
  # ntfy-slots.example.json → ntfy-slots.json (substitute topic prefix)
  if (-not (Test-Path "$TargetHooks\ntfy-slots.json") -or $Force) {
    Deploy-File "$RepoHooks\ntfy-slots.example.json" "$TargetHooks\ntfy-slots.json" -Substitute | Out-Null
  }
}

function Stage-Startup {
  Write-Host "[startup] create Startup folder shortcuts..."
  $WshShell = New-Object -ComObject WScript.Shell

  $lnkInjector = "$StartupDir\ntfy-injector.lnk"
  if (Test-Path $lnkInjector) { Remove-Item $lnkInjector -Force }
  $sc = $WshShell.CreateShortcut($lnkInjector)
  $sc.TargetPath = $AhkExe
  $sc.Arguments = "`"$TargetHooks\ntfy-injector.ahk`""
  $sc.WorkingDirectory = $TargetHooks
  $sc.Save()
  Write-Host "  [OK] $lnkInjector" -ForegroundColor Green

  $lnkWatch = "$StartupDir\ntfy-listener-watchdog.lnk"
  if (Test-Path $lnkWatch) { Remove-Item $lnkWatch -Force }
  $sc = $WshShell.CreateShortcut($lnkWatch)
  $sc.TargetPath = 'powershell.exe'
  $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TargetHooks\run-ntfy-listener.ps1`""
  $sc.WorkingDirectory = $TargetHooks
  $sc.Save()
  Write-Host "  [OK] $lnkWatch" -ForegroundColor Green
}

function Stage-Settings {
  Write-Host "[settings] register hooks in Claude settings.json..."
  if (-not (Test-Path $SettingsJson)) {
    Write-Host "  [ERR] $SettingsJson missing — init Claude Code first" -ForegroundColor Red
    return
  }
  $bak = "$SettingsJson.bak-$(Get-Date -Format 'yyMMddHHmm')"
  Copy-Item $SettingsJson $bak
  Write-Host "  [BAK] $bak" -ForegroundColor DarkGray

  $cfg = Get-Content $SettingsJson -Raw | ConvertFrom-Json
  if (-not $cfg.PSObject.Properties['hooks']) {
    $cfg | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
  }

  function Ensure-Hook {
    param([string]$Event, [string]$Cmd)
    if (-not $cfg.hooks.PSObject.Properties[$Event]) {
      $cfg.hooks | Add-Member -NotePropertyName $Event -NotePropertyValue @() -Force
    }
    $existing = @($cfg.hooks.$Event) | Where-Object {
      $_.hooks | Where-Object { $_.command -like "*$Cmd*" }
    }
    if ($existing) {
      Write-Host "  [KEEP] $Event already has $Cmd"
      return
    }
    $newEntry = [PSCustomObject]@{
      matcher = ''
      hooks = @([PSCustomObject]@{
        type = 'command'
        command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Cmd`""
      })
    }
    $cfg.hooks.$Event = @($cfg.hooks.$Event) + $newEntry
    Write-Host "  [ADD] $Event <- $Cmd" -ForegroundColor Green
  }

  Ensure-Hook 'SessionStart' "$TargetHooks\ntfy-slot-claim.ps1"
  Ensure-Hook 'SessionEnd'   "$TargetHooks\ntfy-slot-release.ps1"
  Ensure-Hook 'Stop'         "$TargetHooks\ntfy-stop.ps1"
  Ensure-Hook 'SessionStart' "$PSScriptRoot\daily-check.ps1"

  if ($cfg.hooks.PSObject.Properties['Notification']) {
    $bad = @($cfg.hooks.Notification) | Where-Object {
      $_.hooks | Where-Object { $_.command -like '*ntfy-stop*' }
    }
    if ($bad) {
      Write-Host "  [WARN] Notification has ntfy-stop (causes duplicate phone push)" -ForegroundColor Red
      Write-Host "         Remove manually" -ForegroundColor Yellow
    }
  }

  $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsJson -Encoding UTF8
  Write-Host "  [SAVED] $SettingsJson" -ForegroundColor Green
}

function Stage-Codex {
  Write-Host "[codex] deploy Codex hooks..."
  Load-Config
  if (-not (Test-Path $TargetCodex)) { New-Item -ItemType Directory -Path $TargetCodex -Force | Out-Null }

  foreach ($name in @('ntfy-stop.ps1','codex-slot-claim-current.ps1','codex-ntfy-dispatch.ps1')) {
    Deploy-File "$RepoCodexHooks\$name" "$TargetCodex\$name" -Substitute | Out-Null
  }

  if (Test-Path $CodexHooksJson) {
    $bak = "$CodexHooksJson.bak-$(Get-Date -Format 'yyMMddHHmm')"
    Copy-Item $CodexHooksJson $bak
    Write-Host "  [BAK] $bak" -ForegroundColor DarkGray
    $hf = Get-Content $CodexHooksJson -Raw | ConvertFrom-Json
  } else {
    $hf = [PSCustomObject]@{ hooks = [PSCustomObject]@{} }
  }
  if (-not $hf.hooks) { $hf | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force }
  if (-not $hf.hooks.PSObject.Properties['Stop']) {
    $hf.hooks | Add-Member -NotePropertyName 'Stop' -NotePropertyValue @() -Force
  }
  $existing = @($hf.hooks.Stop) | Where-Object { $_.command -like "*$TargetCodex*ntfy-stop*" }
  if ($existing) {
    Write-Host "  [KEEP] Codex hooks.json already has ntfy-stop"
  } else {
    $hf.hooks.Stop = @($hf.hooks.Stop) + [PSCustomObject]@{
      type = 'command'
      command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$TargetCodex\ntfy-stop.ps1`""
    }
    Write-Host "  [ADD] Codex Stop <- ntfy-stop.ps1" -ForegroundColor Green
  }
  $hf | ConvertTo-Json -Depth 10 | Set-Content -Path $CodexHooksJson -Encoding UTF8
  Write-Host "  [SAVED] $CodexHooksJson" -ForegroundColor Green
}

function Stage-Smoke {
  Write-Host "[smoke] end-to-end test..."
  Load-Config
  $tk = $env:NTFY_TOKEN
  $url = $env:NTFY_SERVER_URL
  $legacy = $env:NTFY_LEGACY_TOPIC

  Write-Host "  [PC->phone] POST to $legacy ..."
  $code = curl.exe -s -o NUL -w "%{http_code}" -X POST `
    -H "Authorization: Bearer $tk" --data "[setup smoke] PC->phone $(Get-Date -Format 'HH:mm:ss')" `
    "$url/$legacy"
  if ($code -eq '200') {
    Write-Host "  [OK] POST 200 — check phone ntfy app for push" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] HTTP=$code" -ForegroundColor Red
    return
  }

  Write-Host ""
  $slot1 = "$($env:NTFY_TOPIC_PREFIX)-1"
  Write-Host "  [phone->PC] Send 'SMOKE_OK' from phone ntfy app to $slot1" -ForegroundColor Yellow
  Write-Host "  Waiting 30s, watching listener log..."
  $start = Get-Date
  $found = $false
  while (((Get-Date) - $start).TotalSeconds -lt 30) {
    Start-Sleep 2
    $tail = Get-Content "$TargetHooks\ntfy-inbox-debug.txt" -Tail 5 -ErrorAction SilentlyContinue
    if ($tail -match 'SMOKE_OK') { $found = $true; break }
  }
  if ($found) {
    Write-Host "  [OK] listener got SMOKE_OK — full loop works" -ForegroundColor Green
  } else {
    Write-Host "  [TIMEOUT] 30s no signal. Run scripts/doctor.ps1 to diagnose." -ForegroundColor Red
  }
}

switch ($Stage) {
  'verify'   { Stage-Verify }
  'hooks'    { Stage-Hooks;    Stage-Verify }
  'startup'  { Stage-Startup;  Stage-Verify }
  'settings' { Stage-Settings; Stage-Verify }
  'codex'    { Stage-Codex;    Stage-Verify }
  'smoke'    { Stage-Smoke }
  'all'      {
    Stage-Hooks
    Stage-Startup
    Stage-Settings
    Stage-Codex
    Stage-Verify
    Write-Host ""
    Write-Host "Next: configure phone ntfy app (9 slots + 1 legacy topic), then setup.ps1 smoke" -ForegroundColor Yellow
  }
}

Write-Host ""
