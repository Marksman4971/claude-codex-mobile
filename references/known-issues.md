# 已知问题清单 — ntfy 链路 16 项故障模式

> doctor 按本表逐项扫描；fix 按本表 FAIL 处方修复。
> 编号 N{1-5}-X 表示第 N 类的第 X 个：N1=Server/网络，N2=Listener/Watchdog，N3=AHK Injector，N4=Slot 表/HWND，N5=Hook/配置。
> 每条记录：**症状 → 检测方法 → 严重度 → 修复**。新坑发现后追加，doctor.ps1 同步加扫描项。

## §1 Server / 网络（3 项）

### N1-1 server 不可达
- **症状**：手机收/发都失败；PC POST 超时或 connection refused
- **检测**：`curl -s --max-time 5 ${NTFY_SERVER_URL}/v1/health` 不返回 `{"healthy":true}`
- **严重度**：🔴 FAIL（链路完全断）
- **修复**：①检查本地网络/代理 ②SSH aliyun 看 `systemctl status ntfy` ③切 fallback `${NTFY_FALLBACK_HOST}`（仅 Aliyun 真挂时）

### N1-2 token 失效 / ACL 变更
- **症状**：POST 返回 401/403；某些 topic 写不进去
- **检测**：用本机 token 逐 slot POST，发现 ≥1 个返回非 200
- **严重度**：🔴 FAIL
- **修复**：SSH aliyun 跑 `ntfy access` 查权限 → 重新授权 / 重新生成 token → 同步更新 `ntfy-stop.ps1` 里的 Bearer 值

### N1-3 server 响应慢（>2s）
- **症状**：手机消息到达 cc 输入框延迟 >5s
- **检测**：smoke POST 到 listener 收到 marker 的间隔 >2s
- **严重度**：🟡 WARN
- **修复**：可能国内/VPS 带宽抖动，先观察；持续慢 →SSH 看 ntfy server log

## §2 Listener / Watchdog（3 项）

### N2-1 listener 进程不存在
- **症状**：手机发的消息没人收，listener log 无新行
- **检测**：`Get-Process` 找不到 `*ntfy-inbox-listener*` 或 `*run-ntfy-listener*` 的 powershell
- **严重度**：🔴 FAIL
- **修复**：`Start-Process powershell -WindowStyle Hidden -File run-ntfy-listener.ps1`；检查 Startup 文件夹快捷方式

### N2-2 listener 长时间无活动
- **症状**：listener 进程在，但 log 最后一行 >5min（且期间应该有消息）
- **检测**：tail listener log + 当前时间对比；smoke POST 到 server 后 listener log 不更新
- **严重度**：🟡 WARN（可能假死）
- **修复**：kill listener + watchdog 进程，让 Startup 重启 / 手动 spawn

### N2-3 多个 listener 重复运行
- **症状**：手机一条消息触发多次注入
- **检测**：`Get-Process` 出现 ≥2 个 `ntfy-inbox-listener` powershell
- **严重度**：🟡 WARN
- **修复**：kill 多余，保留 watchdog 启动的那一个

## §3 AHK Injector（4 项）

### N3-1 AHK 进程不存在
- **症状**：listener 写剪贴板成功（log 有 "clip OK"），但 cc 输入框无反应；injector log 无新 "marker detected"
- **检测**：`Get-Process AutoHotkey64` 不存在
- **严重度**：🔴 FAIL
- **修复**：`Start-Process "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" ntfy-injector.ahk`；检查 Startup

### N3-2 AHK 假死（Responding=False）
- **症状**：log 有 "marker detected"+"HWND injected"，但实际字符没落到 cc 输入框
- **检测**：`(Get-Process AutoHotkey64).Responding -eq $false`
- **严重度**：🔴 FAIL
- **修复**：kill + 重启 AHK（走 `restart-ahk.ps1`）

### N3-3 AHK 状态漂移（长跑 >12h）
- **症状**：和 N3-2 类似，但 Responding=True；注入字符落到错的窗口或丢失
- **检测**：`StartTime` 距今 >12h；过去 5min 有 marker 但无注入成功
- **严重度**：🟡 WARN（preventive，主动重启）
- **修复**：走 `restart-ahk.ps1` 重置内部 SetForegroundWindow / 线程绑定状态
- **背景**：2026-05-20 首次发现。AHK v2 长跑后焦点抢占机制偶发失效，重启即恢复。详见经验文件

### N3-4 Windows 焦点保护阻塞 WinActivate
- **症状**：用户在其他窗口操作时，AHK 拉不动目标 WT 到最前
- **检测**：注入成功 log 后立即 `GetForegroundWindow` 比对，发现仍非目标 HWND
- **严重度**：🟡 WARN
- **修复**：AHK 脚本里 WinActivate 前加 Alt-key trick（`Send "{Alt}"; Sleep 30`）—— 待 patch 实施

## §4 Slot 表 / HWND（4 项）

### N4-1 slot 表死 PID
- **症状**：发到某 slot 的消息被注入到错的窗口或失败
- **检测**：`Get-Process -Id <slot.pid>` 不存在
- **严重度**：🔴 FAIL
- **修复**：`ntfy-slot-release.ps1`（manual mode = 自动清死 PID）

### N4-2 slot 表 HWND 失效
- **症状**：同 N4-1，但 PID 还活
- **检测**：调 `User32.IsWindow(hwnd)` 返回 false
- **严重度**：🔴 FAIL
- **修复**：同 N4-1，release 该 slot 让新 SessionStart 重新 claim

### N4-3 slot HWND 复用（多 slot 同 HWND）
- **症状**：手机发到不同 slot 都注入到同一窗口
- **检测**：slots.json 里 ≥2 个 slot 的 hwnd 字段相同（非 null）
- **严重度**：🟠 WARN（典型场景：Codex Desktop 多 chat 共用一个 OS 窗口）
- **修复**：保留 1 个有效 slot，其余 release；或开独立 WT 窗口让 SessionStart claim 新 HWND

### N4-4 WT 多 tab 共享一个 HWND
- **症状**：手机发的消息进了同 WT 别的 tab，目标 cc tab 没收到
- **检测**：通过 GetWindowText 取 HWND 当前 active tab title，对比 slot 注册的 session_id/label
- **严重度**：🟠 WARN
- **修复**：用 `Ctrl+Shift+N` 开独立 WT 窗口，**不要**在同 WT 里 `Ctrl+Shift+T` 开 tab

## §5 Hook 注册 / 配置（2 项）

### N5-1 Stop hook 双注册
- **症状**：手机收到完工通知 2 条
- **检测**：parse `~/.claude/settings.json`，发现 `ntfy-stop.ps1` 同时挂在 `Stop` 和 `Notification` 下
- **严重度**：🔴 FAIL
- **修复**：从 `Notification` 段删 `ntfy-stop.ps1`，只在 `Stop` 保留

### N5-2 Startup 快捷方式缺失
- **症状**：开机后 listener / AHK 都不在跑（需手动启）
- **检测**：`%APPDATA%/Microsoft/Windows/Start Menu/Programs/Startup/` 下没有 `ntfy-injector.lnk` 或 `ntfy-listener-watchdog.lnk`
- **严重度**：🟠 WARN
- **修复**：跑 `setup.ps1 startup` 重建快捷方式

## 修复优先级

按 doctor 报告里 FAIL 项的顺序修：

1. **先修 N1-x**（server 不通的话其他都白搭）
2. **再修 N4-x**（死 slot 阻塞 N3-x 注入判定）
3. **再修 N2-x + N3-x**（listener/AHK 进程层）
4. **最后修 N5-x**（配置层，不影响当前 session，下次重启生效）

`fix.ps1 --auto` 自动按此顺序串行修，每修一项跑对应 doctor 子项验证 PASS 才进下一项。

## 新增检查项 TODO

每次踩到新坑追加到此节，doctor.ps1 同步加扫描函数。

- [ ] _（占位：未来新发现的坑）_
