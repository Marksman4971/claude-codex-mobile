---
name: gen-ntfy
description: >-
  PC + 手机 ntfy 通知链路（PC→手机完工推送 + 手机→PC 文字注入）的搭建、诊断、自愈。
  覆盖 ntfy server (Aliyun)、listener、AHK injector、slot 池、Claude Code / Codex hook 集成。
  doctor 一条命令 30 秒出全链路 PASS/WARN/FAIL 报告；fix 按 FAIL 项精准修；
  restart 单独重启 AHK（最高频痛点）；setup 新机器一键搭建。
  触发：/gen-ntfy、手机通知失灵、ntfy 失灵、ntfy 检查、通知失灵、检查通知、手机收不到、
  AHK 不注入、slot 表残留、重新搭 ntfy、新窗口手机收不到、新机器配 ntfy。
  不触发：SyncClipboard 文件同步（→ syncclipboard.md 经验）、ntfy app 内部诊断
  （远程不可达，让用户手动查）、Anthropic 账号通知（→ gen-account-guard）。
user-invocable: true
---

# gen-ntfy — 手机 ntfy 通知链路运维

## 适用场景

- **每日开机自检**：哪个环节断了第一时间发现（SessionStart 自动跑）
- **故障诊断**：手机消息发不出 / 发出去 cc 不响应 / cc 完工手机没收到
- **快速修复**：清死 slot / 重启 AHK / 重启 listener
- **新机器搭建**：服务器配置已就绪时，一键部署本地链路（hooks + Startup + settings）

## 链路一句话

```
PC→手机：Claude Stop hook → ntfy-stop.ps1 → POST ntfy server → 手机 app 收
手机→PC：手机 app → POST ntfy server → listener long-poll → 剪贴板 marker → AHK 抢焦点 → SendText cc 输入框
```

详细架构见 `references/architecture.md`。

## 命令

| 命令 | 说明 | 加载 |
|------|------|------|
| `/gen-ntfy` | 默认：跑 status（短诊断，3 秒出活否清单） | 内嵌 |
| `/gen-ntfy doctor` | 全链路扫描，PASS/WARN/FAIL 报告 + 推荐 action | `scripts/doctor.ps1` |
| `/gen-ntfy fix [--auto]` | 按 doctor 的 FAIL 项精准修。默认逐项确认，`--auto` 一键全修 | `scripts/fix.ps1` |
| `/gen-ntfy restart` | 单独重启 AHK injector（今天的高频痛点） | `scripts/restart-ahk.ps1` |
| `/gen-ntfy setup [stage]` | 新机器搭建本地链路。stage = `all`/`hooks`/`startup`/`settings`/`codex` | `scripts/setup.ps1` + `references/setup.md` |
| `/gen-ntfy status` | 短诊断（只查活否，不出完整报告） | 内嵌 |
| `/gen-ntfy known` | 列出已知问题清单 + 检测/修复对照表 | `references/known-issues.md` |

## 核心铁律

1. **不手动改 `ntfy-slots.json`** —— 除非 doctor 明确指示需要重置某个 slot。手改会让 listener/AHK/hook 三方状态不一致。
2. **修复优先级**：先清死 slot → 再重启 AHK → 再重启 listener watchdog → 最后才查 server。**反过来做会浪费时间**：90% 的故障在前两层。
3. **AHK 跑超过 12h 主动重启**（preventive）—— 实测状态漂移高发期，doctor 会 WARN 提示。
4. **WT 窗口必须 SessionStart 抢 slot** —— 不能手动改 slots.json 添 slot；让 hook 自动 claim。
5. **WT 用独立窗口不用 tab** —— 一个 OS 窗口多 tab → HWND 复用 → AHK 注入到错 tab。WT 里用 `Ctrl+Shift+N` 开新窗口，不是 `Ctrl+Shift+T`。

## 启动行为

每次 Claude Code 启动（SessionStart hook），如果当天首次进入 cc，自动跑一次 `scripts/daily-check.ps1`（轻量版 doctor）。FAIL 才弹出提示，PASS 静默不打扰。

⚠️ daily-check 是 doctor 的子集，跑得快（<3s），只查 5 个高频死亡点：server health / listener 活否 / AHK 活否 / slot 表死 PID 扫描 / 近 5 分钟有无成功注入。

## 模块路由

| 命令 / 场景 | 加载 | 说明 |
|---|---|---|
| `doctor` / 任何完整诊断 | `references/known-issues.md` + 跑 `scripts/doctor.ps1` | 全 16 项检查矩阵 |
| `fix` / 修 FAIL 项 | `references/known-issues.md`（取修复段） + `scripts/fix.ps1` | 按 doctor 报告精准修 |
| `setup` / 搭建 | `references/setup.md` + `references/adapters.md` + `scripts/setup.ps1` | 完整搭建流程 |
| 想理解架构 / 排查未知问题 | `references/architecture.md` | 链路图 + topic 设计 + slot 池原理 |
| 改 hook 注册 / Startup / 服务模式 | `references/adapters.md` | 各环节适配项细节 |

收到命令后先 Read 对应 references，再按指令执行。

## 已知问题速查表

| 类别 | 计数 | 详见 |
|---|---|---|
| Server / 网络 | 3 项 | `references/known-issues.md §1` |
| Listener / Watchdog | 3 项 | §2 |
| AHK Injector | 4 项 | §3 |
| Slot 表 / HWND | 4 项 | §4 |
| Hook 注册 / 配置 | 2 项 | §5 |

完整 16 项检测+修复方法见 `references/known-issues.md`。doctor 跑完后产出 JSON 报告，fix 按报告精准修。

## 与经验文件的关系

- `~/.claude/experiences/notification.md` ← 架构原理 + 历史决策 + 不操作的背景知识
- 本 skill ← 操作层：诊断 / 修 / 搭建

doctor 报告 FAIL 时如需理解"为啥这样修"，去经验文件查；操作执行全部走 skill。

## 完成验证

- [ ] doctor：每个检查项有明确 PASS/WARN/FAIL 判定 + 推荐 action
- [ ] fix：每个 FAIL 类型有对应修复函数 + 修完自动复跑 doctor 该项验证
- [ ] restart：30 秒内重启 AHK 且新进程 Responding=True
- [ ] setup：新机器跑完 `setup all` 后能完成 PC→手机 + 手机→PC 双向 smoke
- [ ] SessionStart daily-check：<3s 完成，FAIL 才弹提示
