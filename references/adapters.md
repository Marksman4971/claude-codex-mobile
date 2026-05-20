# 适配项 — 各环节集成细节

> doctor / fix / setup 操作各环节时引用本文档的具体配置。

## 1. Claude Code hooks 集成

文件：`~/.claude/settings.json`

```json
{
  "hooks": {
    "SessionStart": [{
      "type": "command",
      "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%/.claude/hooks/ntfy-slot-claim.ps1\" -FromHook"
    }],
    "Stop": [
      {"type": "command", "command": "powershell ... <sound-hook>"},
      {"type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%/.claude/hooks/ntfy-stop.ps1\""}
    ],
    "Notification": [
      {"type": "command", "command": "powershell ... <sound-hook>"}
    ],
    "SessionEnd": [{
      "type": "command",
      "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%/.claude/hooks/ntfy-slot-release.ps1\" -FromHook"
    }]
  }
}
```

**铁律**：
- `ntfy-stop.ps1` **只**注册到 `Stop`；**禁止**注册到 `Notification`（导致重复推送）
- `Notification` 段只挂声音 hook

## 2. Codex hooks 集成

文件：`~/.codex/hooks.json`

```json
{
  "hooks": {
    "Stop": [
      {"type": "command", "command": "powershell ... <sound-hook>"},
      {"type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%/.codex/hooks/ntfy-stop.ps1\""}
    ]
  }
}
```

⚠️ 注意：
- Codex Desktop 的 `SessionStart` 不可靠（实测不一定 fire），slot claim 用 PowerShell profile wrapper 或 `codex-slot-claim-current.ps1 -Newest` 手动跑
- Codex CLI 通过 PowerShell `$PROFILE` wrapper 自动 claim slot：调真 codex 前先跑 slot-claim

## 3. Startup 启动项

位置：`%APPDATA%/Microsoft/Windows/Start Menu/Programs/Startup/`

| 快捷方式 | Target | Arguments |
|---|---|---|
| `ntfy-injector.lnk` | `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe` | `"%USERPROFILE%\.claude\hooks\ntfy-injector.ahk"` |
| `ntfy-listener-watchdog.lnk` | `powershell.exe` | `-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%USERPROFILE%\.claude\hooks\run-ntfy-listener.ps1"` |

**为什么不用 Task Scheduler**：实测登录后启动延迟高且偶发不起。Startup 快捷方式 + watchdog 进程崩溃自重启 = 最稳。

## 4. listener 服务化（备选，未启用）

如需把 listener 改为 Windows 服务而不是 Startup：

```powershell
# NSSM 注册（参考 gen-claude-gpt CLIProxyAPI 服务模式）
nssm install NtfyListener "powershell.exe" "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ..."
nssm set NtfyListener Start SERVICE_AUTO_START
Start-Service NtfyListener
```

**何时切服务化**：
- listener 频繁因登录 session 锁定/解锁被 kill
- 需要无人登录也跑（远程开机后立即可用）

## 5. ntfy app 配置规范（手机端）

每个订阅必须三件套齐：

| 字段 | 值 |
|---|---|
| Server | `${NTFY_SERVER_URL}` |
| Topic | `${NTFY_TOPIC_PREFIX}-slot-N` 或 `${NTFY_LEGACY_TOPIC}` |
| Authentication | username = `${NTFY_USER}`，password = 同步 PC token（或独立 user 密码） |

⚠️ 添加新订阅时 **每个都要单独配 auth**——app 不自动继承。这是 2026-05-20 踩坑：以为加了一个 auth 全订阅通用，结果只有第一个能发。

## 6. ntfy-slots.json 写入规则

| 谁写 | 何时 | 写什么 |
|---|---|---|
| `ntfy-slot-claim.ps1`（SessionStart） | 新 cc 窗口启动 | hwnd + pid + session_id + claimed_at + label |
| `ntfy-slot-release.ps1`（SessionEnd / 手动） | cc 窗口关 / 死锁清理 | 清空对应 slot 字段 |
| `ntfy-stop.ps1` | （只读，不写） | 读 session_id 反查 slot-N → POST |
| `ntfy-inbox-listener.ps1` | （只读，不写） | 读 marker_prefix/suffix |

**禁止**：任何 skill / 手动编辑直接改 `slots.json`。要修死锁走 `ntfy-slot-release.ps1`（manual mode）。

## 7. 日志文件位置 + 用途

| 文件 | 用途 | 大小提醒 |
|---|---|---|
| `~/.claude/hooks/ntfy-inbox-debug.txt` | listener 收到消息 / clip OK / skip 等 | 增长慢 |
| `~/.claude/hooks/ntfy-injector.log` | AHK marker detected / inject 结果 | 增长慢 |
| `~/.claude/hooks/ntfy-slot.log` | SessionStart/End claim/release | 增长慢 |
| `~/.claude/hooks/ntfy-listener-watchdog.log` | watchdog 重启历史 | 极慢 |
| `~/.claude/hooks/ntfy-stop.log` | 每次完工推送 | **可能很大**，定期清 |

## 8. 凭据管理

token 放在 3 处（保持同步）：

1. `~/.claude/hooks/ntfy-stop.ps1`（PC 端 publish）
2. `~/.claude/hooks/ntfy-inbox-listener.ps1`（PC 端 subscribe）
3. 手机 ntfy app 每个订阅

⚠️ token 变更时 `setup.ps1 rotate-token` 一键同步前 2 处；手机要手动改。

token 永不写入：
- 本文档
- 经验文件 `notification.md`
- Git 仓库
