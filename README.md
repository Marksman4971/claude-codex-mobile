# claude-codex-mobile

> Phone ↔ Claude Code / Codex bridge with **multi-window slot routing**, via self-hosted ntfy.

## Why?

Anthropic's `claude --rc` (Feb 2026) lets you remote-control **one** running Claude Code session from your phone. Codex has its own mobile app for cloud Codex.

**Neither solves**:

- Running **9 Claude Code windows in parallel**, each addressable from a separate phone chat
- **Mixing Claude Code + Codex CLI + Codex Desktop** under one unified routing scheme
- Doing this **self-hosted**, with all data flowing through your own ntfy server (no Anthropic/OpenAI middleware for the message bus)
- Working with **any future AI CLI** that supports lifecycle hooks (`aider`, `gh copilot`, etc.) — they just plug in

This project does. The trade-off: **Windows only**, requires you to host your own ntfy server.

## Architecture

```
┌─────────────┐   ntfy POST    ┌──────────────┐   poll 1s    ┌──────────────────┐
│ Phone ntfy  │ ─────────────→ │ ntfy server  │ ←──────────  │ PC listener      │
│   app       │                │ (self-host)  │              │ (long-running)   │
└─────────────┘                └──────────────┘              └────────┬─────────┘
       ↑                              ↑                                │ marker
       │ outbox push                  │ Stop hook                      │ ⌬⌬NTFY-{slot-N}⌬⌬msg
       │                              │                                ▼
       │                       ┌──────┴───────┐              ┌──────────────────┐
       └───────────────────────│ cc/Codex     │              │ Windows clipboard│
                               │ on completion│              └────────┬─────────┘
                               └──────────────┘                       │ OnClipboardChange
                                                                      ▼
                                                              ┌──────────────────┐
                                                              │ AHK injector     │
                                                              │ (always running) │
                                                              └────────┬─────────┘
                                                                       │ parse slot-N
                                                                       │ slots.json → HWND
                                                                       ▼
                                                              ┌──────────────────┐
                                                              │ Target terminal  │
                                                              │ SendText + Enter │
                                                              └──────────────────┘
```

**Core abstraction**: a **slot pool** (20 virtual channels `<PREFIX>-1` to `<PREFIX>-20`). Each terminal window claims a free slot on launch (via SessionStart hook). Phone messages on `<PREFIX>-N` route to whichever window owns slot-N. The pool size is a defended constant — extending past 20 means editing the slot array in 6 files (`ntfy-slot-claim.ps1`, `ntfy-slot-release.ps1`, `ntfy-stop.ps1` × 2, `codex-slot-claim-current.ps1`, `codex-slot-release-current.ps1`) plus the listener's topic subscription string and the `ntfy-slots.template.json` schema; 20 is the practical ceiling for one user's API quota and screen real estate.

## Requirements

- Windows 10/11
- PowerShell 5.1+
- [AutoHotkey v2](https://www.autohotkey.com/) — clipboard listener + window injection
- Self-hosted [ntfy server](https://docs.ntfy.sh/install/) — run on a small VPS, ~50MB RAM
- Phone with [ntfy app](https://ntfy.sh/docs/subscribe/phone/) (Android works out of the box; iOS needs HTTPS server)
- Optionally: Claude Code CLI, Codex CLI, Codex Desktop

## What this is NOT

- Not a product / not maintained as one. Personal tool that I open-sourced because the multi-window angle isn't covered by any official tool.
- Not for non-technical users. You need to host a ntfy server and edit PowerShell scripts.
- Not iOS-friendly out of the box (ntfy iOS requires HTTPS server + APN; current default config is HTTP for low-latency LAN/domestic VPS).

## Quick start (≈30 min if you already have a ntfy server)

1. Clone this repo into `~/.claude/hooks/` (or wherever you want):
   ```
   git clone https://github.com/Marksman4971/claude-codex-mobile.git $env:USERPROFILE\claude-codex-mobile
   ```

2. Set up your ntfy server (skip if you already have one):
   - Self-host: see [ntfy docs](https://docs.ntfy.sh/install/)
   - Create a user with read+write access to your topic prefix

3. Copy `config.example.ps1` → `config.ps1` and fill in your server / user / token / topic prefix.

4. Source `config.ps1` in your PowerShell `$PROFILE`:
   ```powershell
   . "$env:USERPROFILE\claude-codex-mobile\config.ps1"
   ```

5. Register hooks in your `~/.claude/settings.json` (Claude Code) and `~/.codex/hooks.json` (Codex CLI):
   - See `hooks/README.md` and `codex-hooks/hooks.example.json` for the template

6. Install AutoHotkey v2, then **register a Scheduled Task to run AHK with highest privileges at logon** (so injection works into elevated/admin terminal windows — UIPI blocks low-IL→high-IL keystrokes):
   ```powershell
   $action = New-ScheduledTaskAction -Execute "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" -Argument '"$env:USERPROFILE\claude-codex-mobile\hooks\ntfy-injector.ahk"'
   $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
   $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
   $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
   Register-ScheduledTask -TaskName "NtfyInjectorElevated" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
   Start-ScheduledTask -TaskName "NtfyInjectorElevated"
   ```
   (Legacy: Startup folder .lnk also works for non-elevated targets only.)

7. Start the listener watchdog:
   ```powershell
   powershell -WindowStyle Hidden -File "$env:USERPROFILE\claude-codex-mobile\hooks\run-ntfy-listener.ps1"
   ```
   Add a shortcut to Startup folder for persistence.

8. On phone, install ntfy app, add subscriptions for `<your-prefix>-1` through `<your-prefix>-9`.

9. Open a Claude Code window → SessionStart auto-claims a slot → send a message from the matching phone chat → see it appear in your terminal.

## Key files

| Path | Role |
|------|------|
| `hooks/ntfy-stop.ps1` | Claude Code Stop hook. Pushes assistant reply to the slot's phone topic |
| `hooks/ntfy-inbox-listener.ps1` | Polls ntfy server for phone messages; wraps with slot marker; writes to clipboard |
| `hooks/run-ntfy-listener.ps1` | Watchdog wrapper. Restarts listener if it crashes |
| `hooks/ntfy-injector.ahk` | AutoHotkey clipboard watcher. Detects marker, routes to target window, injects text + Enter |
| `hooks/ntfy-slot-claim.ps1` | SessionStart hook. Claims first free slot for current foreground window |
| `hooks/ntfy-slot-release.ps1` | SessionEnd hook. Releases slot |
| `hooks/ntfy-slots.example.json` | Slot registry template (9 empty slots) |
| `hooks/lib/UIA.ahk` | UI Automation helper (used as fallback for tab routing) |
| `codex-hooks/ntfy-stop.ps1` | Codex version of Stop hook (matches Codex payload format) |
| `codex-hooks/codex-slot-claim-current.ps1` | Codex Desktop slot claim (since Desktop doesn't fire SessionStart reliably, run manually after opening a new window) |
| `codex-hooks/hooks.example.json` | Codex hooks.json template |
| `config.example.ps1` | Environment variable template |

## Multi-window usage

**For Windows Terminal (cc CLI):**

- ✅ **`Ctrl+Shift+N`** (new independent window) is the cleanest path — each window has its own HWND, slot binding stable
- ⚠️ **`Ctrl+Shift+T`** (new tab) works too as long as you add the `[slot-N]` prefix to the tab title via `/rename`, so AHK Tier 1 UIA can disambiguate. v7.1+ added a Tier 3 "single-tab WT" fallback that handles the common single-tab case without needing the prefix.
- ❌ **`Ctrl+Shift+D`** (split pane) is not supported — panes share window focus opaquely.

**For Codex Desktop** (and any Electron-based AI GUI that lets multiple chats share one window): the host's slot-claim hook fires every time you switch / create a thread, but the hook sees the OS-level foreground window only. If multiple threads live inside one Electron BrowserWindow, all of them collapse to the same HWND → same slot. The **only reliable way to give each thread its own slot is to give each thread its own physical window**.

In Codex Desktop:

- ❌ `Ctrl+N` (new chat) — opens new chat **inside the current window**. Same HWND, slot binding collapses.
- ❌ `Ctrl+Shift+N` (new window) — opens an empty new window. Thread you create afterwards may still spawn in the original window depending on which window has focus at creation time.
- ✅ **"Open the current chat in a new window"** (键盘快捷键 → 在新窗口中打开). Default **unassigned**; bind to e.g. `Ctrl+Shift+W`. Right-click on a thread in the sidebar also works. This is the **only** action that actually moves a thread out of its host window into a new BrowserWindow with a new HWND. After that move, the thread sticks to its own window and slot-claim binds it cleanly.

PASS 5 in `codex-hooks/codex-slot-claim-current.ps1` auto-claims slots for any orphan visible Codex window, so once a thread has its own window the binding happens at next hook fire with no manual step.

**This pattern generalises**: if a future Anthropic / Google / etc. AI Desktop GUI adopts the same "many threads in one Electron window" model, the same fix applies — find an "Open in new window" command and bind a shortcut. If a host doesn't expose that command, only the CLI variant routes cleanly.

### Critical operational rule: open Codex windows ONE AT A TIME

Empirically (2026-05-20 testing): pressing the "Open in new window" shortcut **multiple times in quick succession** does NOT reliably split threads into distinct BrowserWindows. Codex's SessionStart hook fires for each new window, but `GetForegroundWindow` doesn't have time to settle on the newly-created window before the next hook fires — multiple threads collapse to the original window's HWND.

**Correct procedure**:

1. Select thread #1 in Codex sidebar → press your "Open in new window" shortcut → wait ~1 second for the new window to fully open AND become foreground
2. Verify slot-claim wrote a new slot entry (optional: tail `~/.codex/hooks/codex-slot-claim-current.log`)
3. THEN move to thread #2 → repeat
4. Continue until all desired threads are in their own windows

Doing 5 threads sequentially with ~1s pauses produces 5 distinct slot bindings. Doing them simultaneously with rapid key presses produces 1 slot binding and 4 silent orphan windows.

Also note: **Codex Desktop does NOT persist thread→window mapping across app restart**. On cold start it may pack multiple threads back into one window. You'll have to re-split after every Codex restart.

## Recent improvements (2026-05-20, v7.x line)

- **5-tier injection routing** (`ntfy-injector.ahk`): exact `[slot-N]` UIA → fuzzy `slot-N` UIA → single-tab WT auto-detect → non-WT Electron host (Codex/ChatGPT/VS Code/Cursor) with UIA composer find + pixel fallback → fail-loud ntfy alert to phone (never HWND-blind injection).
- **Idle-gate before inject** (v7.7): AHK waits up to 5 s for `A_TimeIdle ≥ 500 ms` before stealing focus, so your active typing in window A doesn't leak into window B mid-keystroke when a phone message arrives.
- **Focus restore with fail-soft**: WT path restores immediately after SendText; Electron path waits 1.5 s then restores. If restore fails, log + carry on — never block the inject.
- **UIPI bypass via Scheduled Task**: AHK runs as Highest privileges; injects work into admin/elevated terminal windows that low-IL AHK can't reach.
- **Topic-stable across window churn** (`ntfy-slot-claim.ps1` PASS 2): close cc, open new cc → SessionStart reclaims the orphan slot, keeping the same topic number, so your phone subscriptions never need to change.
- **Codex same-window thread switching** (`codex-slot-claim-current.ps1` PASS 3): switching threads inside one Codex window reuses the existing slot instead of fragmenting the slot pool with duplicate HWNDs.
- **Send-NtfyFile helper**: `Send-NtfyFile -Path foo.png -Title "..."` pushes files to the right phone topic by env-var session-id lookup; auto-picks ntfy tag emoji by file extension.

## Limitations

- Windows only. Linux/macOS would need a different injection mechanism (xdotool / AppleScript).
- iOS users: ntfy iOS app needs HTTPS server with valid cert; the low-latency HTTP+IP setup won't push notifications. Set up a HTTPS reverse proxy if you need iOS.
- Listener restart-on-crash works, but if the ntfy server itself goes down, you need to restart it.
- Codex Desktop GUI doesn't realtime-refresh from disk-level session updates — the IPC route (`NTFY_CODEX_APP_SERVER_DISPATCH=1`) routes correctly per thread but the message only appears after you re-open the thread; default AHK route shows in GUI but only inside the visible thread of the bound window. Pick based on whether you value correct-thread-routing or live GUI display.

## Tooling (optional)

The `scripts/` directory adds an automation + diagnostics layer on top of the manual deployment described in Quick start. Use it if you want one-command deploy + ongoing health checks instead of editing `settings.json` and managing the listener by hand.

```powershell
scripts/setup.ps1 all       # Read config.ps1 → substitute ${NAME} placeholders → deploy to ~/.claude/hooks/
                            #   + register Claude/Codex hooks + create Startup shortcuts
scripts/doctor.ps1          # 13-check PASS/WARN/FAIL report (server / listener / AHK / slot table / hooks)
scripts/fix.ps1             # Auto-fix FAIL items found by doctor (dead slots, stuck AHK, missing watchdog, ...)
scripts/restart-ahk.ps1     # Restart the AHK injector (most common single-command fix)
scripts/daily-check.ps1     # Lightweight doctor (~3s) — register as SessionStart hook for daily self-check
```

If you ran the manual Quick start above, `scripts/doctor.ps1` already works against the deployed `~/.claude/hooks/` — no extra config needed. The `setup.ps1 all` workflow is an alternative to the manual hook editing in steps 4-7 of Quick start.

Detailed docs:

| Doc | Content |
|-----|---------|
| `SKILL.md` | Entry point for Claude Code users who install this as a skill |
| `references/architecture.md` | Full link diagram + design decisions (why slot pool / why clipboard marker / why HWND fallback) |
| `references/known-issues.md` | 16 failure modes with detection + fix recipes |
| `references/adapters.md` | Per-integration config (Claude hooks / Codex hooks / Startup / Auth) |
| `references/setup.md` | Expanded walkthrough mirroring Quick start with every flag |

## License

GPL v3 — see [LICENSE](LICENSE).

> **Why GPL (not MIT)?** This is personal infrastructure I open-sourced so others can use and improve it. The copyleft requirement (anyone who forks/redistributes must release under GPL too) is intentional: I don't want this repackaged into a closed-source commercial product. If you fix a bug or add a feature, GPL ensures the improvement flows back to the community.

## Acknowledgements

- [ntfy](https://ntfy.sh/) — the messaging substrate
- [AutoHotkey v2](https://www.autohotkey.com/) — the injection engine
- [Descolada/UIA-v2](https://github.com/Descolada/UIA-v2) — UI Automation library
