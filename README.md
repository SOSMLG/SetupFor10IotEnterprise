# Win10/Win11 IoT (Enterprise) LTSC adaptation (slim)


## Scope (per your choices)
- Shell: stock PowerShell 5.1 + minimal profile.
- WM: Komorebi + whkd.
- Browser: Helium (`ImputNet.Helium` via winget, Win10+) instead of Edge.
- Panel: stock Windows taskbar, tuned with native settings.
- Debloat: IE11, Edge, Windows Media Player, PowerShell ISE, WordPad, OneDrive removed after install (Helium/VLC/VSCodium replace them; `-NoDebloat` to skip, already-gone parts just log and continue). Telnet client intentionally kept (old bench gear/scripts may still call it).

## Kept + fixed for LTSC
| File | Fix |
|---|---|
| `PowerShell/profile` | minimal UTF-8 + Clear-Host base, PS 5.1 safe |
| `Git/.gitconfig` | main branch, autocrlf, codium editor, prune, aliases. identity left blank for you |
| `Komorebi/komorebi.json` | fixed `boarder_style` typo → `border_style`, 10 workspaces, stock borders |
| `VSCodium/settings.json` | fixed invalid JSON (`],` → `},`); deploys to `%APPDATA%\VSCodium\User\` |
| `Komorebi/whkdrc`, `File-Explorer/config.ini` (optional) | copied as-is |
| `Vesktop/settings.json` + `quickcss.css`, `qBittorrent/qbittorrent.ini`, `VLC/vlcrc`, `OBS/profiles/Recording/basic.ini`, `Helium/master_preferences` | deployed fresh-install-only, read each folder's README for the 2-minute finish |

## Keybinds (Sway port, WIN = Sway Mod4)
`Win+Return` PowerShell, `Win+T` files, `Win+Z` Helium, `Win+A` opencode,
`Win+H/J/K/L`+arrows focus, `Win+Shift+…` move, `Win+1..0` / `Win+Shift+1..0`
workspaces, `Win+Space` float, `Win+F` monocle, `Win+M` maximize,
`Win+Alt+H/J/K/L` resize, `Win+Shift+C` reload, `Win+Shift+E` stop WM.
Native (unbound): `Win` Start, `Win+V` clipboard, `Win+Shift+S` snip,
`Win+X` power menu, `Win+L` locks (can't be captured). Gaps mirror sway:
inner 5, outer 0. Komorebi can't auto-assign apps to workspaces like sway
`assign` - park apps once per session with `Win+Shift+Num`.

## Install
- Online: `powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1` (+ `-IncludeOptional` for Obsidian/Spotify, `-NoTweaks` to skip tweaks)
- Tweaks-only: same script with `-TweaksOnly` runs just the Titus tweaks (+O&O) on any live machine. No apps, no configs, no debloat. This is what the minimal ISO uses.
- Drivers: universal image, so drivers go on manually per device (vendor NIC/wifi packs after first connect, or Windows Update once online).
- Offline/ISO: `ISO/Get-Offline.ps1` to pre-seed per-ID subfolders, then `-OfflineDir <path> -Unattended` (works with no winget at all). Installer waits up to 4 min for DHCP on first boot before declaring offline.
- Still manual: fonts (JetBrainsMono Nerd, Monocraft) into `Fonts/`, Helium default-browser confirm.
- Automation lab: MATLAB via campus license, USB-serial drivers (CH340/CP210x/ST-Link) via `-DriverDir <inf-folder>` or manually, vendor tools (CODESYS/TIA/Studio 5000) from their own installers.
- AI assistant: `opencode` CLI is preinstalled (`SST.opencode`) + sidebar in VSCodium. Auth is interactive: installer drops `Win-Iot-Finish.cmd` on the Public Desktop, double-click it once (`opencode auth login`). Reads anything text: `.m`, `.py`, ladder exports, docs.
- Tweaks (Titus-style, native reg, `-NoTweaks` to skip): restore point first; O&O ShutUp10++ with titus cfg, then our reg values so ours win overlaps; telemetry 0 (Enterprise-honored), DiagTrack/dmwappushservice disabled, 10 services to Manual (maps/xbox/retail/wallet/insider/CDP); updates = notify before download + no auto-reboot + no driver pushes (Win10 is cumulative so security-only split is impossible - LTSC + notify is the sane equivalent); Delivery Optimization off; silent BitLocker auto-encryption blocked; location off; WPBT execution off; smb1/llmnr/netbios off; remote assistance off; lsass protected; wdigest off; guest off; firewall+defender on; Bing/Cortana/consumer apps/GameDVR/taskbar-feeds (Win10 Widgets stand-in)/store-suggestions/error-reporting/USB-autorun off; extensions shown; This PC default; folder-type auto-discovery off; long paths on; temp files + disk cleanup; hibernate off; `-Fixes` repairs dns/winsock/update stack on demand. Taskbar tuned with plain settings: small icons, never-combine labels, seconds clock, tray all out, junk buttons gone, classic mixer + alt-tab, no shake, stock colors, fast menus, numlock, verbose boot. Win11-only (right-click End Task, start-menu layout) skipped with a log note. True blur styling, middle-click actions and scroll-volume need a hooking engine and are out of scope. Also: background apps off, IPv4 preferred (full IPv6 kill breaks things, skipped), chosen DNS (`-Dns`, Cloudflare default) on live adapters, toasts + notification center off, best-performance base with ClearType, shadows and content-dragging kept, animations/peek off, fast key repeat, storage sense off, OneDrive gone, reserved storage off, teredo off, RTC in UTC, inking/typing AI leftovers off, dark mode on (taskbar + apps), world formats en-001, verbose bluescreens, svchost split matched to ram, defender exclusions for lab folders that exist.
- Runtimes install FIRST via winget: full VC++ stack 2005→2022 (x86+x64, old vendor tools need the ancient ones), .NET 8 Desktop Runtime, .NET Framework 3.5 + DirectPlay features enabled. .NET 4.8 is already in-box on both LTSC builds.

## Verify
- `komorebic state`, `whkd --version`
- No `applications.json` needed: the old `app_specific_configuration_path` key
  hard-crashed Komorebi when the file was missing, so it was removed. Float
  rules now go inline in `komorebi.json` as `floating_applications`
  (`{"kind":"Exe","id":"notepad.exe","matching_strategy":"Equals"}` style).
