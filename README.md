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

**Core abstraction**: a **slot pool** (9 virtual channels `<PREFIX>-1` to `<PREFIX>-9`). Each terminal window claims a free slot on launch (via SessionStart hook). Phone messages on `<PREFIX>-N` route to whichever window owns slot-N.

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

6. Install AutoHotkey v2, then add `hooks/ntfy-injector.ahk` to your Startup folder (or run it manually).

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

**Each terminal window must have a distinct HWND.** For Windows Terminal:

- ✅ Use **`Ctrl+Shift+N`** (new independent window) — each window has its own HWND, routing works
- ❌ Do NOT use **`Ctrl+Shift+T`** (new tab) or **`Ctrl+Shift+D`** (split pane) — these share the parent window's HWND, routing will collapse to whichever tab/pane is active

For Claude Code: every new window auto-claims the next free slot on SessionStart.

For Codex Desktop: SessionStart hook fires unreliably; after opening a new Codex Desktop window, manually run:
```powershell
& "$env:USERPROFILE\claude-codex-mobile\codex-hooks\codex-slot-claim-current.ps1"
```

## Limitations

- Windows only. Linux/macOS would need a different injection mechanism (xdotool / AppleScript).
- iOS users: ntfy iOS app needs HTTPS server with valid cert; the low-latency HTTP+IP setup won't push notifications. Set up a HTTPS reverse proxy if you need iOS.
- Codex Desktop multi-window requires manual slot claim per window (no auto-fire SessionStart).
- Listener restart-on-crash works, but if the ntfy server itself goes down, you need to restart it.

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
