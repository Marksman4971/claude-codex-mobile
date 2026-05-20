<#
.SYNOPSIS
  Dispatch one phone->Codex ntfy message through Codex app-server protocol.

.DESCRIPTION
  This avoids fragile AHK keyboard injection for Codex Desktop. The listener
  writes one JSON message file, then starts this script. This script waits until
  the target thread looks idle, resumes it via app-server stdio, and starts a
  normal user turn with the phone text.
#>
[CmdletBinding()]
param(
  [string]$MessageFile,
  [string]$ThreadId,
  [string]$Text,
  [string]$MessageId,
  [int]$WaitForIdleSec = 1800,
  [int]$TurnTimeoutSec = 1800,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$LogPath = "$env:USERPROFILE\.codex\hooks\codex-ntfy-dispatch.log"
$LockDir = "$env:USERPROFILE\.codex\hooks\ntfy-dispatch-locks"

function Log {
  param([string]$Message)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Add-Content -LiteralPath $LogPath -Value "[$ts] $Message" -Encoding UTF8
}

function Get-CodexExe {
  $primary = "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
  if (Test-Path -LiteralPath $primary) { return $primary }
  $bins = @(Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\OpenAI\Codex\bin" -Recurse -Filter codex.exe -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending)
  if ($bins.Count -gt 0) { return $bins[0].FullName }
  throw "codex.exe not found under $env:LOCALAPPDATA\OpenAI\Codex\bin"
}

function Get-ThreadSessionFile {
  param([string]$Id)
  $root = "$env:USERPROFILE\.codex\sessions"
  $match = @(Get-ChildItem -LiteralPath $root -Recurse -Filter "*$Id.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($match.Count -eq 0) { return $null }
  return $match[0].FullName
}

function Wait-ThreadIdle {
  param([string]$Id, [int]$TimeoutSec)
  $sessionFile = Get-ThreadSessionFile -Id $Id
  $marker = "$env:USERPROFILE\.codex\computer-use-turn-ended\$Id"
  if (-not $sessionFile -or -not (Test-Path -LiteralPath $marker)) {
    Log "idle check skipped thread=$Id sessionFile=$sessionFile markerExists=$(Test-Path -LiteralPath $marker)"
    return $true
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $lastStart = $null
    $completedTurns = @{}
    try {
      $lines = Get-Content -LiteralPath $sessionFile -Tail 5000 -Encoding UTF8
      foreach ($line in $lines) {
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($obj.type -ne 'event_msg') { continue }
        if ($obj.payload.type -eq 'task_started') {
          $lastStart = [string]$obj.payload.turn_id
        } elseif ($obj.payload.type -eq 'task_complete') {
          $completedTurns[[string]$obj.payload.turn_id] = $true
        }
      }
    } catch {
      Log "session state parse failed thread=$Id error=$($_.Exception.Message)"
    }

    if ($lastStart) {
      if ($completedTurns.ContainsKey($lastStart)) { return $true }
      Log "thread busy thread=$Id activeTurn=$lastStart; waiting"
      Start-Sleep -Seconds 2
      continue
    }

    $sessionTime = (Get-Item -LiteralPath $sessionFile).LastWriteTimeUtc
    $markerTime = (Get-Item -LiteralPath $marker).LastWriteTimeUtc
    if ($markerTime -ge $sessionTime.AddSeconds(-2)) { return $true }
    Log "thread busy thread=$Id session=$($sessionTime.ToString('o')) marker=$($markerTime.ToString('o')); waiting"
    Start-Sleep -Seconds 2
  }
  return $false
}

function ConvertTo-JsonRpcAscii {
  param([string]$Json)

  $sb = [System.Text.StringBuilder]::new($Json.Length)
  foreach ($ch in $Json.ToCharArray()) {
    $code = [int][char]$ch
    if ($code -le 0x7f) {
      [void]$sb.Append($ch)
    } else {
      [void]$sb.Append('\u')
      [void]$sb.Append($code.ToString('x4'))
    }
  }
  return $sb.ToString()
}

function New-JsonLine {
  param([int]$Id, [string]$Method, $Params)
  $json = @{
    jsonrpc = '2.0'
    id = $Id
    method = $Method
    params = $Params
  } | ConvertTo-Json -Depth 50 -Compress
  ConvertTo-JsonRpcAscii -Json $json
}

function Drain-Queues {
  param($OutQueue, $ErrQueue, [hashtable]$State)

  $line = $null
  while ($OutQueue.TryDequeue([ref]$line)) {
    if (-not $line) { continue }
    try {
      $obj = $line | ConvertFrom-Json -ErrorAction Stop
      if ($obj.id) { $State["response:$($obj.id)"] = $obj }
      if ($obj.method -eq 'turn/completed') { $State['turnCompleted'] = $obj }
      if ($obj.method -eq 'turn/started') { $State['turnStarted'] = $obj }
      if ($obj.method -eq 'error') { Log "rpc error notification: $line" }
    } catch {
      Log "rpc stdout: $line"
    }
  }

  $err = $null
  while ($ErrQueue.TryDequeue([ref]$err)) {
    if ($err) { Log "rpc stderr: $err" }
  }
}

function Wait-RpcResponse {
  param($OutQueue, $ErrQueue, [hashtable]$State, [int]$Id, [int]$TimeoutSec, $Process)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    Drain-Queues -OutQueue $OutQueue -ErrQueue $ErrQueue -State $State
    $key = "response:$Id"
    if ($State.ContainsKey($key)) { return $State[$key] }
    if ($Process.HasExited) { throw "app-server exited before response id=$Id code=$($Process.ExitCode)" }
    Start-Sleep -Milliseconds 100
  }
  throw "timeout waiting for rpc response id=$Id"
}

function Invoke-CodexTurn {
  param([string]$Id, [string]$Body, [int]$TimeoutSec)

  $codex = Get-CodexExe
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $codex
  # Windows PowerShell 5 may run on .NET Framework where ArgumentList is not
  # available; use a simple argument string for this fixed command.
  $psi.Arguments = 'app-server --listen stdio://'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $psi.CreateNoWindow = $true

  $proc = [System.Diagnostics.Process]::new()
  $proc.StartInfo = $psi
  $outQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
  $errQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
  $state = @{}

  Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $outQueue -Action {
    if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
  } | Out-Null
  Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $errQueue -Action {
    if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
  } | Out-Null

  [void]$proc.Start()
  $proc.BeginOutputReadLine()
  $proc.BeginErrorReadLine()

  try {
    $proc.StandardInput.WriteLine((New-JsonLine -Id 1 -Method 'initialize' -Params @{
      clientInfo = @{ name = 'ntfy-codex-dispatch'; version = '0.1' }
      capabilities = @{ experimentalApi = $true }
    }))
    $proc.StandardInput.Flush()
    $init = Wait-RpcResponse -OutQueue $outQueue -ErrQueue $errQueue -State $state -Id 1 -TimeoutSec 20 -Process $proc
    if ($init.error) { throw "initialize failed: $($init.error | ConvertTo-Json -Compress -Depth 8)" }

    $proc.StandardInput.WriteLine((New-JsonLine -Id 2 -Method 'thread/resume' -Params @{ threadId = $Id }))
    $proc.StandardInput.Flush()
    $resume = Wait-RpcResponse -OutQueue $outQueue -ErrQueue $errQueue -State $state -Id 2 -TimeoutSec 60 -Process $proc
    if ($resume.error) { throw "thread/resume failed: $($resume.error | ConvertTo-Json -Compress -Depth 8)" }

    $proc.StandardInput.WriteLine((New-JsonLine -Id 3 -Method 'turn/start' -Params @{
      threadId = $Id
      input = @(@{ type = 'text'; text = $Body })
    }))
    $proc.StandardInput.Flush()
    $turnResp = Wait-RpcResponse -OutQueue $outQueue -ErrQueue $errQueue -State $state -Id 3 -TimeoutSec 60 -Process $proc
    if ($turnResp.error) { throw "turn/start failed: $($turnResp.error | ConvertTo-Json -Compress -Depth 8)" }

    $turnId = [string]$turnResp.result.turn.id
    Log "turn started thread=$Id turn=$turnId"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
      Drain-Queues -OutQueue $outQueue -ErrQueue $errQueue -State $state
      if ($state.ContainsKey('turnCompleted')) {
        $done = $state['turnCompleted']
        if ($done.params.threadId -eq $Id -and $done.params.turn.id -eq $turnId) {
          $status = [string]$done.params.turn.status
          Log "turn completed thread=$Id turn=$turnId status=$status"
          if ($status -ne 'completed') { throw "turn ended with status=$status" }
          return
        }
      }
      if ($proc.HasExited) { throw "app-server exited during turn code=$($proc.ExitCode)" }
      Start-Sleep -Milliseconds 250
    }
    throw "timeout waiting for turn completion thread=$Id turn=$turnId"
  } finally {
    try { $proc.StandardInput.Close() } catch {}
    if (-not $proc.HasExited) {
      try { $proc.Kill() } catch {}
    }
  }
}

try {
  if ($MessageFile) {
    $job = Get-Content -LiteralPath $MessageFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $ThreadId) { $ThreadId = [string]$job.threadId }
    if (-not $Text) { $Text = [string]$job.text }
    if (-not $MessageId) { $MessageId = [string]$job.id }
  }

  if (-not $ThreadId) { throw 'ThreadId is required' }
  if (-not $Text) { throw 'Text is required' }
  if (-not $MessageId) { $MessageId = [guid]::NewGuid().ToString() }

  Log "dispatch start id=$MessageId thread=$ThreadId len=$($Text.Length)"

  if ($DryRun) {
    Log "dry run only id=$MessageId thread=$ThreadId text=$($Text.Substring(0, [Math]::Min(80, $Text.Length)))"
    exit 0
  }

  New-Item -ItemType Directory -Path $LockDir -Force | Out-Null
  $safeThread = $ThreadId -replace '[^A-Za-z0-9_.-]', '_'
  $lockPath = Join-Path $LockDir "$safeThread.lock"
  $lock = $null
  $lockDeadline = (Get-Date).AddSeconds($WaitForIdleSec)
  while ((Get-Date) -lt $lockDeadline) {
    try {
      $lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
      break
    } catch {
      Start-Sleep -Seconds 2
    }
  }
  if (-not $lock) { throw "timeout acquiring dispatch lock: $lockPath" }

  try {
    if (-not (Wait-ThreadIdle -Id $ThreadId -TimeoutSec $WaitForIdleSec)) {
      throw "thread did not become idle within ${WaitForIdleSec}s"
    }
    Invoke-CodexTurn -Id $ThreadId -Body $Text -TimeoutSec $TurnTimeoutSec
  } finally {
    if ($lock) { $lock.Close() }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }

  if ($MessageFile -and (Test-Path -LiteralPath $MessageFile)) {
    Move-Item -LiteralPath $MessageFile -Destination "$MessageFile.done" -Force
  }
  Log "dispatch ok id=$MessageId thread=$ThreadId"
  exit 0
} catch {
  Log "dispatch fail id=$MessageId thread=$ThreadId error=$($_.Exception.Message)"
  if ($MessageFile -and (Test-Path -LiteralPath $MessageFile)) {
    try {
      Set-Content -LiteralPath "$MessageFile.fail" -Value $_.Exception.ToString() -Encoding UTF8
    } catch {}
  }
  exit 1
}
