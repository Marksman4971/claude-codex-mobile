# UIA.ahk

This directory is for [Descolada/UIA-v2](https://github.com/Descolada/UIA-v2/blob/main/Lib/UIA.ahk) — a 424KB AutoHotkey v2 UI Automation library.

We don't redistribute it here. Download it manually:

```powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'  # if needed
Invoke-WebRequest `
  -Uri 'https://raw.githubusercontent.com/Descolada/UIA-v2/main/Lib/UIA.ahk' `
  -OutFile "$env:USERPROFILE\claude-codex-mobile\hooks\lib\UIA.ahk"
```

`ntfy-injector.ahk` includes it as `#Include lib\UIA.ahk`.

Without this library, AHK injector will fail at startup. Either download it as above or remove the `#Include` line and the UIA-based tab routing fallback (you'll lose multi-tab UIA routing but HWND routing for independent windows still works).
