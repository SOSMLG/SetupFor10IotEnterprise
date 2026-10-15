# Windows Terminal

`-IncludeStudy` installs `Microsoft.WindowsTerminal` and drops a
`settings.json` into
`%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\`
on a fresh install only (fresh = terminal never launched).

What it sets:
- default profile: Windows PowerShell 5.1. pwsh and cmd sit next in the list
- dark, JetBrainsMono Nerd Font 10, 10k scrollback, comfy padding
- stock color scheme, nothing fancy

if the terminal already ran once, our file loses (fresh-only rule). edit by
hand, or re-run with `-ConfigsOnly` to overwrite it.
