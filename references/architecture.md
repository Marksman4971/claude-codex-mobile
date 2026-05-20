# 架构原理 — ntfy 通知链路

> 本文档解释**为什么这么设计**。操作执行走 `../SKILL.md` 的命令；故障诊断走 `known-issues.md`。

## 双向链路图

```
PC → 手机（完工推送）
────────────────────────
Claude Code / Codex 完工
  ↓ Stop hook
ntfy-stop.ps1
  ↓ 读 ntfy-slots.json 匹配 session_id → slot-N
  ↓ POST -H "Authorization: Bearer <TOKEN>" ${NTFY_SERVER_URL}/${NTFY_TOPIC_PREFIX}-slot-N
ntfy server (Aliyun)
  ↓ push to subscriber
手机 ntfy app


手机 → PC（文字注入）
────────────────────────
手机 ntfy app
  ↓ POST ${NTFY_TOPIC_PREFIX}-slot-N
ntfy server (Aliyun)
  ↓ long-poll connection
ntfy-inbox-listener.ps1
  ↓ wrap clipboard: ⌬⌬NTFY-slot-N⌬⌬<text>
Windows clipboard
  ↓ OnClipboardChange event
ntfy-injector.ahk (AutoHotkey v2)
  ↓ parse marker → 查 slots.json → 取 HWND
  ↓ WinActivate(HWND) + Sleep(150) + SendText + Send {Enter}
Claude Code / Codex 输入框
```

## 关键设计决策

### 1. 为什么 ntfy 不用 SaaS / 自建

- ntfy.sh 公共 server 国内访问不稳定
- Aliyun VPS 直连 IP (`${NTFY_SERVER_HOSTPORT}`) 绕 SNI/域名封锁
- HTTP 不上 HTTPS：直连 IP 不需要证书；HTTPS 反而引入证书过期/换 IP 麻烦
- Fallback：`https://${NTFY_FALLBACK_HOST}` 是早期 Vultr 路由，保留备用

### 2. 为什么用 slot 池（slot-1..9）不是单 topic

- 多 cc / Codex 窗口并行时，必须区分目标
- session_id 复杂，topic 字符串简单：手机 app 一个 topic 一个聊天窗
- slot-N 是**虚拟通道**，slot-N 不是历史窗口序号——释放后可被新窗口重新 claim

### 3. 为什么用剪贴板 marker 不直接 IPC

- 跨进程：listener（PowerShell）↔ injector（AHK）—— 剪贴板是最简共享通道
- marker 格式 `⌬⌬NTFY-slot-N⌬⌬text`：使用 U+232C BENZENE RING 字符避免与正常文本冲突
- listener 写 marker → AHK OnClipboardChange 触发 → 解析后把 clean text 回写剪贴板 → 用户 Ctrl+V 也能粘贴

### 4. 为什么 AHK 用 HWND + UIA 双路由

- UIA 路由：能识别 WT 内的 tab name 含 `[slot-N]` —— 同 WT 多 tab 时唯一可行的方式
- HWND 路由：单 WT 单 tab 时直接 WinActivate(HWND)，最可靠
- **实测**：UIA tab routing 几乎永远 fail（WT custom title 和 tab name 不同步），所以始终 fallback 到 HWND
- **教训**：HWND 不能区分同 WT 内的 tab → 用独立 WT 窗口（Ctrl+Shift+N）

### 5. 为什么 listener 用 watchdog 不用 Task Scheduler

- Task Scheduler 在 Windows 登录后启动时延高 + 偶发不起
- Startup 文件夹快捷方式 + watchdog 进程崩溃自动重启 = 经实测最稳

### 6. 为什么 Stop hook 不能挂 Notification

- ntfy-stop.ps1 注册到 `Notification` 会让每条 cc 消息都触发推送（不只是完工）
- 必须只在 `Stop` 注册，`Notification` 只挂声音

## Topic 命名约定

| Topic | 角色 |
|---|---|
| `${NTFY_LEGACY_TOPIC}` | Legacy/默认 + 完工 fallback。slot 匹配失败时完工消息发到这里。手机发到这里默认路到 slot-1。 |
| `${NTFY_TOPIC_PREFIX}-slot-1` .. `${NTFY_TOPIC_PREFIX}-slot-9` | 9 个 slot 通道，每个对应一个独立 WT 窗口的 cc / Codex |

⚠️ Topic 数量上限 9 是约定，不是 server 限制——slot 池容量。需要更多并发窗口的话扩 slot 池得改 listener + injector + slot-claim 三处。

## Slot 表 schema

文件：`~/.claude/hooks/ntfy-slots.json`

```json
{
  "version": 1,
  "marker_prefix": "⌬⌬NTFY-",
  "marker_suffix": "⌬⌬",
  "slots": {
    "slot-N": {
      "topic": "${NTFY_TOPIC_PREFIX}-slot-N",
      "hwnd": <int>,           // OS window handle
      "pid": <int>,            // process id (用于死活判定)
      "session_id": "<uuid>",  // cc / codex session id
      "claimed_at": "yyyy-MM-dd HH:mm:ss",
      "label": "WindowsTerminal PID=<pid>"
    }
  }
}
```

字段语义：
- `hwnd` 是 listener+AHK 抢焦点用，每次 SessionStart 必须重新探测当前前台 WT 的 HWND
- `pid` 用于"进程死了 = slot 失效"的判定
- `session_id` 用于 Stop hook 反查（cc 完工时知道发到哪个 slot）

## 关键文件清单

详见 `adapters.md`，速览：

```
~/.claude/hooks/                          ← cc 端
├── ntfy-stop.ps1                         完工推送
├── ntfy-inbox-listener.ps1               长轮询所有 slot topic
├── run-ntfy-listener.ps1                 watchdog 包装器
├── ntfy-injector.ahk                     抢焦点+注入
├── lib/UIA.ahk                           UIA helper（fallback 用）
├── ntfy-slots.json                       slot 表（运行时状态）
├── ntfy-slot-claim.ps1                   SessionStart 抢 slot
├── ntfy-slot-release.ps1                 SessionEnd 释放 / 手动清死锁
├── ntfy-target.json                      legacy 单 target 绑定（保留兼容）
└── *.log                                 各组件日志

~/.codex/hooks/                           ← codex 端
├── ntfy-stop.ps1                         codex 完工推送（slot-aware）
└── codex-slot-claim-current.ps1          codex desktop fallback claim

%APPDATA%/Microsoft/Windows/Start Menu/Programs/Startup/
├── ntfy-injector.lnk                     开机自启 AHK
└── ntfy-listener-watchdog.lnk            开机自启 watchdog
```

## 历次架构演进

| 日期 | 动作 |
|---|---|
| 2026-05-04 | ntfy 自建（Vultr 海外），单 topic，仅完工推送 |
| 2026-05-19 上午 | phone→PC 通过剪贴板 marker + AHK 注入打通 |
| 2026-05-19 下午 | server 主路由切 Aliyun（直连 IP），延迟降低 |
| 2026-05-19 晚上 | slot 池 1..9 + SessionStart/End claim/release + watchdog + Codex CLI profile wrapper |
| 2026-05-19 夜 | Codex hooks 接入同 slot 池（$CODEX_HOME/hooks.json）|
| 2026-05-20 | 本 skill 立项，把诊断/修复/搭建从经验文件流程化 |
