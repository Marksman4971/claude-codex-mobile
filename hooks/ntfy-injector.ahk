#Requires AutoHotkey v2.0
#SingleInstance Force
SetTitleMatchMode 2

#Include lib\UIA.ahk

; ntfy → clipboard marker → AHK → route to target window
; Routing strategy (in order):
;   1. UIA: find WT tab with name containing "[slot-N]" → click that tab → SendText
;   2. HWND: look up slots.json, use bound HWND → activate window → SendText
;   3. Fallback: first claimed slot's HWND
;   4. Last resort: any ahk_exe WindowsTerminal.exe window

global TARGET_FILE := A_AppData "\..\..\.claude\hooks\ntfy-target.json"
global SLOTS_FILE := A_AppData "\..\..\.claude\hooks\ntfy-slots.json"
global LOG_FILE := A_AppData "\..\..\.claude\hooks\ntfy-injector.log"
global Processing := false
global LastText := ""
global LastTick := 0
global DEDUP_MS := 10000

Log(msg) {
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    try FileAppend("[" ts "] " msg "`n", LOG_FILE, "UTF-8")
}

ReadSlotHwnd(slotId) {
    if !FileExist(SLOTS_FILE)
        return 0
    try {
        json := FileRead(SLOTS_FILE, "UTF-8")
        if RegExMatch(json, '"' slotId '"\s*:\s*\{[^}]*?"hwnd"\s*:\s*(\d+)', &m)
            return Integer(m[1])
    } catch as e {
        Log("read slots failed: " e.Message)
    }
    return 0
}

ReadFirstClaimedHwnd() {
    if !FileExist(SLOTS_FILE)
        return 0
    try {
        json := FileRead(SLOTS_FILE, "UTF-8")
        if RegExMatch(json, '"hwnd"\s*:\s*(\d+)', &m)
            return Integer(m[1])
    } catch {
    }
    return 0
}

ShowToast(title, body) {
    preview := SubStr(body, 1, 100)
    TrayTip(preview, title, 17)
    SetTimer(() => TrayTip(), -3500)
}

; Try UIA route: find a WT tab whose name contains "[slot-N]", focus it
TryUIARoute(slotId, text) {
    needle := "[" slotId "]"
    wtList := WinGetList("ahk_exe WindowsTerminal.exe")
    if wtList.Length = 0 {
        Log("UIA: no WT window")
        return false
    }
    for hwnd in wtList {
        try {
            wtEl := UIA.ElementFromHandle(hwnd)
            if !wtEl
                continue
            ; Search descendant TabItem elements; match by Name containing our slot tag
            cond := {Type:"TabItem"}
            tabs := wtEl.FindAll(cond, 4)  ; scope = Descendants
            for tab in tabs {
                tabName := ""
                try tabName := tab.Name
                if InStr(tabName, needle) {
                    Log("UIA: found tab '" tabName "' in WT hwnd=" hwnd)
                    WinActivate("ahk_id " hwnd)
                    WinWaitActive("ahk_id " hwnd, , 1)
                    try tab.Click()  ; click to focus this tab
                    Sleep(200)  ; let tab transition
                    SendText(text)
                    Sleep(80)
                    Send("{Enter}")
                    Log("UIA injected to tab '" tabName "': " SubStr(text, 1, 60))
                    return true
                }
            }
        } catch as e {
            Log("UIA scan WT " hwnd " err: " e.Message)
        }
    }
    Log("UIA: no matching tab for " needle " in any WT")
    return false
}

InjectToHwnd(hwnd, text, slotId) {
    targetSpec := ""
    if (hwnd != 0 && WinExist("ahk_id " hwnd)) {
        targetSpec := "ahk_id " hwnd
        Log("HWND route: using " slotId " HWND=" hwnd)
    } else {
        fb := ReadFirstClaimedHwnd()
        if (fb != 0 && fb != hwnd && WinExist("ahk_id " fb)) {
            targetSpec := "ahk_id " fb
            Log("HWND route: " slotId " HWND=" hwnd " dead, fallback to first claimed HWND=" fb)
        } else {
            targetSpec := "ahk_exe WindowsTerminal.exe"
            if !WinExist(targetSpec) {
                Log("HWND route: no target anywhere - giving up")
                ShowToast("Inject FAILED", "no target window for " slotId)
                return false
            }
            Log("HWND route: " slotId " dead, fallback to any WindowsTerminal")
        }
    }
    try {
        WinActivate(targetSpec)
        WinWaitActive(targetSpec, , 1)
        Sleep(150)
        SendText(text)
        Sleep(80)
        Send("{Enter}")
        Log("HWND injected (" slotId "): " SubStr(text, 1, 60))
        return true
    } catch as e {
        Log("HWND inject failed: " e.Message)
        return false
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

    ; STAGE 1: try UIA tab routing
    if (slotId != "legacy") {
        if TryUIARoute(slotId, clean)
            return
        Log("UIA route failed, falling back to HWND")
    }

    ; STAGE 2: HWND-based routing (legacy / UIA failed)
    hwnd := slotId = "legacy" ? ReadFirstClaimedHwnd() : ReadSlotHwnd(slotId)
    InjectToHwnd(hwnd, clean, slotId)
}

Log("ntfy-injector v4 started (UIA tab routing + HWND fallback)")
TrayTip("UIA tab routing + HWND fallback", "ntfy-injector v4", 17)
SetTimer(() => TrayTip(), -3000)
