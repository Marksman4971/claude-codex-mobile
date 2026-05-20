#Requires AutoHotkey v2.0
#SingleInstance Force
SetTitleMatchMode 2

#Include lib\UIA.ahk

; ntfy → clipboard marker → AHK → route to target window
; Routing strategy (in order):
;   Tier 1 (exact)    : UIA find WT tab with name containing "[slot-N]" → click → SendText
;   Tier 2 (fuzzy)    : UIA find WT tab with name containing "slot-N" (any position; unique only)
;                       → handles cases where /rename overwrote the [slot-N] prefix
;   Tier 3 (single-tab): slot's bound HWND's WT has exactly 1 TabItem → that tab is necessarily
;                        this slot's tab (no title needed) → inject. Safe because uniquely identified.
;                        Skips when the WT has multiple tabs (ambiguous).
;   Tier 4 (fail-loud): all above failed → push high-priority ntfy alert to the slot's topic so
;                       user knows to /rename [slot-N] and resend. NEVER HWND-blind inject —
;                       that keystroke-dumped messages into whichever tab happened to be focused.
; Legacy markers (no slot id) are still refused.

global TARGET_FILE := A_AppData "\..\..\.claude\hooks\ntfy-target.json"
global SLOTS_FILE := A_AppData "\..\..\.claude\hooks\ntfy-slots.json"
global LOG_FILE := A_AppData "\..\..\.claude\hooks\ntfy-injector.log"
global ALERT_HELPER := A_AppData "\..\..\.claude\hooks\ntfy-alert.ps1"
global MARK_INJECT_HELPER := A_AppData "\..\..\.claude\hooks\ntfy-mark-inject.ps1"
global LISTENER_SCRIPT := A_AppData "\..\..\.claude\hooks\run-ntfy-listener.ps1"
global Processing := false
global LastText := ""
global LastTick := 0
global DEDUP_MS := 10000

Log(msg) {
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    try FileAppend("[" ts "] " msg "`n", LOG_FILE, "UTF-8")
}

ReadSlotTopic(slotId) {
    if !FileExist(SLOTS_FILE)
        return ""
    try {
        json := FileRead(SLOTS_FILE, "UTF-8")
        if RegExMatch(json, '"' slotId '"\s*:\s*\{[^}]*?"topic"\s*:\s*"([^"]+)"', &m)
            return m[1]
    } catch as e {
        Log("read slot topic failed: " e.Message)
    }
    return ""
}

ReadSlotHwnd(slotId) {
    if !FileExist(SLOTS_FILE)
        return 0
    try {
        json := FileRead(SLOTS_FILE, "UTF-8")
        if RegExMatch(json, '"' slotId '"\s*:\s*\{[^}]*?"hwnd"\s*:\s*(\d+)', &m)
            return Integer(m[1])
    } catch as e {
        Log("read slot hwnd failed: " e.Message)
    }
    return 0
}

ShowToast(title, body) {
    preview := SubStr(body, 1, 100)
    TrayTip(preview, title, 17)
    SetTimer(() => TrayTip(), -3500)
}

; Save the foreground window so we can restore it after injection — user keeps the
; window they were actually using; cc only flashes for ~200ms during SendText.
GetForegroundSnapshot() {
    try {
        return WinGetID("A")  ; "A" = currently active window
    } catch as e {
        return 0
    }
}

; Wait until the user stops typing/clicking before stealing focus to inject.
; Prevents cross-window contamination: user types in window A, phone msg arrives
; for window B, AHK WinActivate(B) — if not waited, ~230ms of user keystrokes leak
; into B before AHK SendText fires + restores. With this gate, AHK pauses until
; A_TimeIdle >= idleThresholdMs (user not pressing anything), then injects.
; Returns true if user went idle, false if max wait elapsed (inject anyway).
WaitForUserIdle(idleThresholdMs := 500, maxWaitMs := 5000) {
    waited := 0
    while (waited < maxWaitMs) {
        idle := A_TimeIdle
        if (idle >= idleThresholdMs)
            return true
        sleepFor := idleThresholdMs - idle + 50
        if (sleepFor < 50)
            sleepFor := 50
        Sleep(sleepFor)
        waited += sleepFor
    }
    return false
}

; Restore previous foreground after inject. Fail-soft — never throws back to caller.
; If the previous foreground is dead, gone, or restore fails for any reason, just
; log and move on. The inject already succeeded; restore is a nice-to-have for UX.
RestoreForegroundSafe(prevHwnd, injectedHwnd) {
    if !prevHwnd
        return
    ; If previous foreground IS the inject target, no-op (avoids gratuitous reactivate)
    if (prevHwnd = injectedHwnd)
        return
    try {
        if WinExist("ahk_id " prevHwnd) {
            WinActivate("ahk_id " prevHwnd)
            Log("focus restored to prev hwnd=" prevHwnd)
        } else {
            Log("focus restore skipped: prev hwnd=" prevHwnd " no longer exists")
        }
    } catch as e {
        Log("focus restore failed (non-fatal, inject already succeeded): " e.Message)
    }
}

; Tier 1: exact match — tab name contains "[slot-N]"
TryUIARouteExact(slotId, text) {
    needle := "[" slotId "]"
    return TryUIAByNeedle(slotId, text, needle, "exact")
}

; Tier 2: fuzzy match — tab name contains "slot-N" anywhere (unique only)
TryUIARouteFuzzy(slotId, text) {
    return TryUIAByNeedle(slotId, text, slotId, "fuzzy")
}

; Internal: UIA tab search by needle. tier label is for logging only.
; For fuzzy mode require unique match across all WT windows to avoid wrong-tab injection.
TryUIAByNeedle(slotId, text, needle, tier) {
    wtList := WinGetList("ahk_exe WindowsTerminal.exe")
    if wtList.Length = 0 {
        Log("UIA " tier ": no WT window")
        return false
    }
    matches := []  ; collect all matching tabs (for fuzzy uniqueness check)
    for hwnd in wtList {
        try {
            wtEl := UIA.ElementFromHandle(hwnd)
            if !wtEl
                continue
            cond := {Type:"TabItem"}
            tabs := wtEl.FindAll(cond, 4)  ; scope = Descendants
            for tab in tabs {
                tabName := ""
                try tabName := tab.Name
                if InStr(tabName, needle) {
                    matches.Push({tab: tab, name: tabName, wt: hwnd})
                    if tier = "exact" {
                        ; exact mode: first match wins (legacy behaviour)
                        break
                    }
                }
            }
            if tier = "exact" && matches.Length > 0
                break
        } catch as e {
            Log("UIA " tier " scan WT " hwnd " err: " e.Message)
        }
    }
    if matches.Length = 0 {
        Log("UIA " tier ": no tab matches '" needle "'")
        return false
    }
    if tier = "fuzzy" && matches.Length > 1 {
        names := ""
        for m in matches
            names .= "'" m.name "', "
        Log("UIA fuzzy: ambiguous (" matches.Length " matches) for '" needle "': " names " - skipping to avoid wrong target")
        return false
    }
    hit := matches[1]
    Log("UIA " tier ": picked '" hit.name "' in WT hwnd=" hit.wt)
    prevFg := GetForegroundSnapshot()
    try {
        WinActivate("ahk_id " hit.wt)
        WinWaitActive("ahk_id " hit.wt, , 1)
        try hit.tab.Click()
        Sleep(200)
        SendText(text)
        Sleep(80)
        Send("{Enter}")
        Log("UIA " tier " injected to '" hit.name "': " SubStr(text, 1, 60))
        ; Restore foreground (fail-soft — does not affect inject success above)
        RestoreForegroundSafe(prevFg, hit.wt)
        return true
    } catch as e {
        Log("UIA " tier " inject failed: " e.Message)
        return false
    }
}

; Tier 3: slot's HWND's WT has exactly 1 TabItem → that tab is uniquely this slot's tab,
; so we can inject without depending on title. Skip when WT has multiple tabs (ambiguous).
TryUIASingleTab(slotId, text) {
    hwnd := ReadSlotHwnd(slotId)
    if hwnd = 0 {
        Log("Tier3 single-tab: no slot HWND registered for " slotId)
        return false
    }
    if !WinExist("ahk_id " hwnd) {
        Log("Tier3 single-tab: slot HWND=" hwnd " not a live window")
        return false
    }
    try {
        wtEl := UIA.ElementFromHandle(hwnd)
        if !wtEl {
            Log("Tier3 single-tab: UIA can't read WT hwnd=" hwnd)
            return false
        }
        cond := {Type:"TabItem"}
        tabs := wtEl.FindAll(cond, 4)
        if tabs.Length != 1 {
            Log("Tier3 single-tab: WT hwnd=" hwnd " has " tabs.Length " tabs - ambiguous, skipping")
            return false
        }
        tab := tabs[1]
        tabName := ""
        try tabName := tab.Name
        Log("Tier3 single-tab: WT hwnd=" hwnd " has 1 tab '" tabName "' - safe to inject")
        prevFg := GetForegroundSnapshot()
        ; Note: skip tab.Click() because WT puts focus into the terminal pane on WinActivate
        ; when there's only 1 tab. tab.Click() can route focus into the tab bar chrome
        ; instead, causing SendText keystrokes to land nowhere visible. Empirically the v5
        ; HWND-only path (WinActivate + Sleep + SendText) is the one that worked.
        WinActivate("ahk_id " hwnd)
        WinWaitActive("ahk_id " hwnd, , 1)
        Sleep(150)
        SendText(text)
        Sleep(80)
        Send("{Enter}")
        Log("Tier3 single-tab injected to '" tabName "': " SubStr(text, 1, 60))
        ; Restore foreground (fail-soft — inject already succeeded)
        RestoreForegroundSafe(prevFg, hwnd)
        return true
    } catch as e {
        Log("Tier3 single-tab error: " e.Message)
        return false
    }
}

; Tier 3b: slot HWND points to a non-WT host (Codex Desktop, ChatGPT, VS Code, etc.).
; These don't expose TabItems via UIA in the WT-tab sense; inject directly with
; app-specific composer focus when known. Reuses the v5 Codex composer-click hack.
TryGenericHwnd(slotId, text) {
    hwnd := ReadSlotHwnd(slotId)
    if hwnd = 0 {
        Log("Tier3b generic: no slot HWND for " slotId)
        return false
    }
    if !WinExist("ahk_id " hwnd) {
        Log("Tier3b generic: slot HWND=" hwnd " not a live window")
        return false
    }
    procName := ""
    try procName := WinGetProcessName("ahk_id " hwnd)
    ; Tier 3 (the WT single-tab path) is the right path for WT; skip here to avoid double-injection.
    if procName = "WindowsTerminal.exe" {
        Log("Tier3b generic: " procName " is WT — leave to Tier 3, skip")
        return false
    }
    Log("Tier3b generic: " procName " hwnd=" hwnd " — best-effort inject")
    prevFg := GetForegroundSnapshot()
    try {
        WinActivate("ahk_id " hwnd)
        WinWaitActive("ahk_id " hwnd, , 1)
        Sleep(150)
        ; Focus the composer via UIA (most reliable across Codex/Cursor/VSCode updates).
        ; Walk the UIA tree to find an Edit/Document/ContentEditable element, prefer the
        ; LOWEST one (composer is at the bottom of the window). Fallback: pixel-offset click.
        focused := false
        try {
            wEl := UIA.ElementFromHandle(hwnd)
            if wEl {
                ; Search Edit + Document control types (Electron text input exposes one of these)
                editEls := wEl.FindAll({Type:"Edit"}, 4)
                if !editEls || editEls.Length = 0
                    editEls := wEl.FindAll({Type:"Document"}, 4)
                if editEls && editEls.Length > 0 {
                    ; Pick the BOTTOM-most editable element (composer is at the bottom)
                    bottomEl := editEls[1]
                    bottomY := -1
                    for el in editEls {
                        try {
                            rect := el.BoundingRectangle
                            if (rect.b > bottomY) {
                                bottomY := rect.b
                                bottomEl := el
                            }
                        } catch as _ignored {
                            ; skip elements without a readable rect
                        }
                    }
                    try {
                        bottomEl.SetFocus()
                        focused := true
                        Log("Tier3b: UIA SetFocus on bottom-most editable (y=" bottomY ") for " procName)
                    } catch as e1 {
                        ; SetFocus might not be supported — fall through to click on element rect
                        try {
                            rect := bottomEl.BoundingRectangle
                            CoordMode("Mouse", "Screen")
                            Click(Round((rect.l + rect.r) / 2), Round((rect.t + rect.b) / 2))
                            focused := true
                            Log("Tier3b: UIA-located element clicked (rect center) for " procName)
                        } catch as e2 {
                            Log("Tier3b: UIA element click failed: " e2.Message)
                        }
                    }
                }
            }
        } catch as e {
            Log("Tier3b: UIA composer-find failed (will fallback to pixel-click): " e.Message)
        }
        ; Fallback for Codex/ChatGPT if UIA path didn't find an editable: legacy v5 click
        if (!focused && (InStr(procName, "Codex") || InStr(procName, "ChatGPT"))) {
            try {
                WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
                CoordMode("Mouse", "Screen")
                ; Try 3 click positions from bottom up — first one that lands in composer wins
                ; (we can't tell which worked, so just click all 3 quickly; harmless if all hit composer)
                Click(wx + Round(ww / 2), wy + wh - 45)
                Sleep(50)
                Log("Tier3b: fallback pixel-click at y=wh-45 for " procName)
            } catch as focusErr {
                Log("Tier3b composer fallback click skipped: " focusErr.Message)
            }
        }
        Sleep(150)
        SendText(text)
        Sleep(80)
        Send("{Enter}")
        Log("Tier3b generic injected to " procName " (" slotId "): " SubStr(text, 1, 60))
        ; Mark slot so the response Stop hook can route back here, not by foreground heuristic
        MarkSlotInjected(slotId)
        ; Wait for Electron to process keystrokes before restoring focus.
        Sleep(1500)
        RestoreForegroundSafe(prevFg, hwnd)
        return true
    } catch as e {
        Log("Tier3b generic inject failed: " e.Message)
        return false
    }
}

; Mark slot's last_inject_at so the next Codex Stop hook for the resulting thread
; can prefer this slot over GetForegroundWindow heuristic. Fail-soft.
MarkSlotInjected(slotId) {
    try {
        cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' MARK_INJECT_HELPER '" -SlotId "' slotId '"'
        Run(cmd, , "Hide")
    } catch as e {
        Log("mark-inject failed (non-fatal): " e.Message)
    }
}

; Tier 4: push fail-loud alert to user's phone via ntfy. NO HWND-blind injection.
; Returns the message to the same topic the user sent from, so they see it next to their original.
AlertUserNoTarget(slotId, text) {
    topic := ReadSlotTopic(slotId)
    if topic = "" {
        Log("alert: no topic registered for " slotId " — cannot notify")
        return
    }
    ; Diagnose: is the slot's HWND alive? If dead → tell user the closed-loop recovery path.
    hwnd := ReadSlotHwnd(slotId)
    hwndAlive := (hwnd > 0 && WinExist("ahk_id " hwnd))
    preview := SubStr(text, 1, 80)
    if StrLen(text) > 80
        preview .= "..."
    title := "AHK route failed: " slotId
    if hwndAlive {
        body := "[" slotId "] tab not found in its WT window (multi-tab ambiguous or title hidden). Run '/rename [" slotId "]' in that cc window then resend.`n`nOriginal:`n" preview
    } else {
        body := "[" slotId "] window is dead. Just open a new cc window — SessionStart will auto-reclaim slot '" slotId "', keeping topic '" topic "' so you don't need to resubscribe. Then resend.`n`nOriginal:`n" preview
    }
    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' ALERT_HELPER '" -Topic "' topic '" -Title "' title '" -Body "' StrReplace(body, '"', '\"') '"'
    try {
        Run(cmd, , "Hide")
        state := hwndAlive ? "tab-lost" : "window-dead"
        Log("alert: pushed " state " notice to " topic " for " slotId)
    } catch as e {
        Log("alert: spawn helper failed: " e.Message)
    }
}

OnClipboardChange(ClipChanged)

ClipChanged(DataType) {
    global Processing, LastText, LastTick, DEDUP_MS
    if Processing
        return
    if (DataType != 1)
        return
    text := A_Clipboard
    if (text = "")
        return

    bz := Chr(0x232C)
    pattern := "^" bz bz "NTFY(?:-(slot-\d+))?" bz bz "(.*)$"
    if !RegExMatch(text, "s)" pattern, &m)
        return

    slotId := m[1] != "" ? m[1] : "legacy"
    clean := m[2]

    ; Dedup
    now := A_TickCount
    if (clean == LastText && (now - LastTick) < DEDUP_MS) {
        Log("DEDUP skip (" slotId "): " SubStr(clean, 1, 40))
        Processing := true
        A_Clipboard := clean
        Sleep(50)
        Processing := false
        return
    }
    LastText := clean
    LastTick := now
    Log("marker detected slot=" slotId " len=" StrLen(clean))

    Processing := true
    A_Clipboard := clean
    Sleep(50)
    Processing := false

    if (slotId = "legacy") {
        Log("legacy marker refused: no target slot")
        ShowToast("Inject FAILED", "legacy marker has no target slot")
        return
    }

    ; Idle-gate: wait until user stops typing before stealing focus to inject.
    ; Prevents cross-window contamination (your keystrokes for slot-A leaking into
    ; slot-B while AHK has focus on slot-B during the inject window).
    if (!WaitForUserIdle(500, 5000))
        Log("idle-gate: max wait elapsed, injecting anyway (user still typing)")

    ; Tier 1: exact "[slot-N]" UIA match
    if TryUIARouteExact(slotId, clean)
        return
    Log("Tier1 exact failed, trying Tier2 fuzzy")

    ; Tier 2: fuzzy "slot-N" UIA match (unique only — ambiguous returns false)
    if TryUIARouteFuzzy(slotId, clean)
        return
    Log("Tier2 fuzzy failed, trying Tier3 single-tab")

    ; Tier 3: slot's HWND's WT has exactly 1 TabItem → uniquely identified, safe to inject
    if TryUIASingleTab(slotId, clean)
        return
    Log("Tier3 single-tab failed, trying Tier3b generic host (Codex/VS Code/etc.)")

    ; Tier 3b: non-WT host (Codex Desktop, ChatGPT, VS Code, Cursor, ...) — WinActivate + composer click + SendText
    if TryGenericHwnd(slotId, clean)
        return
    Log("Tier3b generic failed, escalating to Tier4 fail-loud alert")

    ; Tier 4: fail-loud alert via ntfy push, NEVER HWND-blind inject
    AlertUserNoTarget(slotId, clean)
    ShowToast("Inject FAILED", "no target for [" slotId "]; check phone for recovery instructions")
}

; ============================================================
; Listener watchdog — 5-second polling layer (v7.9+)
; ============================================================
; The listener (PowerShell long-poll loop) MUST run in the user session for
; clipboard write access. NSSM as SYSTEM doesn't work (Session 0 isolation).
; Task Scheduler with 1-min repetition is layer-2 safety net. THIS in-AHK
; watchdog is layer-1: polls every 5s, respawns if missing. Self-heal in <10s.
;
; Architecture:
;   Layer 1 (this) :  AHK SetTimer 5s    → listener absent → Run()
;   Layer 2 (Task) :  NtfyListenerWatchdog 1-min repeat → revives if AHK + listener both dead
;   Layer 3 (logon):  AtLogOn trigger     → boot / login revival

CheckListenerAlive() {
    try {
        for proc in ComObjGet("winmgmts:\\.\root\cimv2").ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='powershell.exe'") {
            cmd := ""
            try cmd := proc.CommandLine
            if (cmd && (InStr(cmd, "run-ntfy-listener") || InStr(cmd, "ntfy-inbox-listener"))) {
                return  ; alive
            }
        }
    } catch as e {
        Log("watchdog: WMI query failed (non-fatal, skipping spawn): " e.Message)
        return  ; safe fallback — don't blindly spawn
    }
    Log("watchdog: listener not running, spawning via Run()")
    spawnCmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' LISTENER_SCRIPT '"'
    try Run(spawnCmd, , "Hide")
    catch as e
        Log("watchdog: Run failed: " e.Message)
}

SetTimer(CheckListenerAlive, 5000)
CheckListenerAlive()  ; immediate check on AHK start, no need to wait 5s

Log("ntfy-injector v7.9 started (4-tier + Tier3b + idle-gate + last_inject_at + listener watchdog 5s)")
TrayTip("v7.9: listener watchdog", "ntfy-injector v7.9", 17)
SetTimer(() => TrayTip(), -3000)
