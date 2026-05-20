# 新机器搭建 — 从零到能用

> 本文档是**可复现**搭建流程。每步给命令 / 文件 / 验证方法。
> 自动化部分走 `scripts/setup.ps1 <stage>`；需要 SSH / 改 server / 手机端配置的部分必须人工。

## 依赖前置

| 依赖 | 用途 | 必装 |
|---|---|---|
| AutoHotkey v2 | injector | ✅（装到 `C:\Program Files\AutoHotkey\v2\`） |
| PowerShell 5.1+ | listener / hook / setup | ✅（Windows 自带） |
| curl.exe | smoke 测试 / setup 验证 | ✅（Win10+ 自带） |
| Aliyun VPS + ntfy server | 中转 | ✅（前置部署，本文档假设已就绪） |
| 手机 ntfy app | 收发端 | ✅（Android/iOS 应用商店） |
| Claude Code CLI | hook 宿主 | ✅ |
| Codex CLI / Desktop | 可选（如需 codex 端也接通） | ⚪ |

## 五阶段流程

```
1. server 端     ← SSH，手动（一次性）
2. hooks 文件部署 ← setup.ps1 hooks
3. Startup 启动项 ← setup.ps1 startup
4. Claude settings ← setup.ps1 settings
5. Codex hooks   ← setup.ps1 codex（可选）
6. 手机 app 订阅 ← 手动
7. 端到端 smoke   ← setup.ps1 smoke
```

## Stage 1: Server 端（手动一次性）

### 1.1 ntfy server 安装

> _（待补：完整 systemd unit + ntfy install 命令；目前依赖 Aliyun VPS 已部署 `/etc/ntfy/server.yml`）_

参考配置（`/etc/ntfy/server.yml`）：
```yaml
base-url: "${NTFY_SERVER_URL}"
listen-http: ":5034"
cache-file: "/var/cache/ntfy/cache.db"
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
attachment-cache-dir: "/var/cache/ntfy/attachments"
visitor-request-limit-burst: 500
visitor-request-limit-replenish: "1s"
```

### 1.2 创建 admin 用户

```bash
sudo ntfy user add --role=admin ${NTFY_USER}
# 然后输密码

# 验证
sudo ntfy access  # 应看到 ${NTFY_USER} (role: admin)
```

### 1.3 生成 access token

```bash
sudo ntfy token add ${NTFY_USER}
# 输出形如 tk_xxxxxxxxxxxxxxxxxxxxx，记下来
```

### 1.4 验证

```bash
curl -X POST -H "Authorization: Bearer <TOKEN>" \
  --data "STAGE1_OK" \
  ${NTFY_SERVER_URL}/${NTFY_TOPIC_PREFIX}-test
# 期望 HTTP 200 + JSON 含 event:message
```

## Stage 2: Hooks 文件部署（自动）

```powershell
& "$env:USERPROFILE\.claude\skills\gen-ntfy\scripts\setup.ps1" hooks
```

会做的事：
- 创建 `~/.claude/hooks/` 目录（若不存在）
- 拷贝 7 个核心文件到位：
  - `ntfy-stop.ps1` / `ntfy-inbox-listener.ps1` / `run-ntfy-listener.ps1`
  - `ntfy-injector.ahk` / `lib/UIA.ahk`
  - `ntfy-slot-claim.ps1` / `ntfy-slot-release.ps1`
- 初始化空 `ntfy-slots.json`（9 个空 slot）
- 让用户输入 token，写入 `ntfy-stop.ps1` + `ntfy-inbox-listener.ps1`

> _（待补：setup.ps1 hooks 子命令实现，引用 `assets/` 下的模板源文件）_

## Stage 3: Startup 启动项（自动）

```powershell
& "$env:USERPROFILE\.claude\skills\gen-ntfy\scripts\setup.ps1" startup
```

会做的事：
- 在 `%APPDATA%/Microsoft/Windows/Start Menu/Programs/Startup/` 创建两个快捷方式：
  - `ntfy-injector.lnk` → AutoHotkey64.exe + ntfy-injector.ahk
  - `ntfy-listener-watchdog.lnk` → powershell -WindowStyle Hidden + run-ntfy-listener.ps1
- 立即启动两个进程（不等下次重启）

## Stage 4: Claude Code settings.json（自动）

```powershell
& "$env:USERPROFILE\.claude\skills\gen-ntfy\scripts\setup.ps1" settings
```

会做的事：在 `~/.claude/settings.json` 的 `hooks` 段写入：

```json
{
  "hooks": {
    "SessionStart": [{
      "type": "command",
      "command": "powershell ... ntfy-slot-claim.ps1 -FromHook"
    }],
    "Stop": [{
      "type": "command",
      "command": "powershell ... ntfy-stop.ps1"
    }],
    "SessionEnd": [{
      "type": "command",
      "command": "powershell ... ntfy-slot-release.ps1 -FromHook"
    }]
  }
}
```

⚠️ **绝不要把 `ntfy-stop.ps1` 挂到 `Notification`**（详见 known-issues N5-1）。

## Stage 5: Codex hooks.json（可选自动）

```powershell
& "$env:USERPROFILE\.claude\skills\gen-ntfy\scripts\setup.ps1" codex
```

会做的事：
- 复制 `ntfy-stop.ps1` 到 `~/.codex/hooks/`（codex 版本，参数略不同）
- 在 `~/.codex/hooks.json` 写入 `Stop` event hook
- Codex Desktop 需要时跑 `codex-slot-claim-current.ps1 -Newest` 手动 claim

## Stage 6: 手机 app（手动）

1. 装 ntfy app（Android: Google Play / F-Droid；iOS: App Store）
2. 设置 → Add server → URL `${NTFY_SERVER_URL}`，勾选 "Use authentication"，填用户名 `${NTFY_USER}` + 密码（或 token）
3. 订阅 10 个 topic（每个新建一个 subscription）：
   - `${NTFY_LEGACY_TOPIC}`（legacy/默认）
   - `${NTFY_TOPIC_PREFIX}-slot-1` .. `${NTFY_TOPIC_PREFIX}-slot-9`
4. **每个订阅检查**：长按订阅 → Edit → 确认 "Server" 是同一个，"Authentication" 已填

⚠️ 这是 2026-05-20 踩坑教训：app 里每个订阅的 auth 是独立配置的，新订阅默认不带，导致"只有 slot-1 能发"。

## Stage 7: 端到端 Smoke（自动）

```powershell
& "$env:USERPROFILE\.claude\skills\gen-ntfy\scripts\setup.ps1" smoke
```

会做的事：
- PC→手机：跑一次假 Stop hook，验证手机收到推送
- 手机→PC：让用户从手机发 "SMOKE" 到 slot-1，验证 cc 输入框出现 "SMOKE"
- 输出 PASS/FAIL 报告

完成后跑 `/gen-ntfy doctor` 应全 PASS。

## Setup 速查（搭一台新机器）

```powershell
# 一键全跑（除手机外）：
& "$env:USERPROFILE\.claude\skills\gen-ntfy\scripts\setup.ps1" all

# 手机配好后跑 smoke 验证
& "$env:USERPROFILE\.claude\skills\gen-ntfy\scripts\setup.ps1" smoke
```

## TODO（待 Phase 2-3 填充）

- [ ] `setup.ps1` 各 stage 子命令实现
- [ ] `assets/` 下放模板源文件（hooks 文件的 canonical 副本）
- [ ] Stage 1 server 部署的完整 systemd unit + 安装脚本
- [ ] 手机端配置的截图指引
