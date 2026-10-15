# Win10/Win11 IoT (Enterprise) LTSC adaptation (slim)


## Scope (per your choices)
- Shell: stock PowerShell 5.1 + shell pack in the profile (starship, zoxide, fzf, bat, eza, fastfetch; native binaries, every hook guarded).
- WM: Komorebi + whkd.
- Browser: Helium (`ImputNet.Helium` via winget, Win10+) instead of Edge.
- Study (opt-in): `-IncludeStudy` adds Zotero, SumatraPDF, MiKTeX, Typst, Windows Terminal + their configs. each folder has a 2-minute README.
- Panel: stock Windows taskbar, tuned with native settings.
- Debloat: IE11, Edge, Windows Media Player, PowerShell ISE, WordPad, OneDrive removed after install (Helium/VLC/VSCodium replace them; `-NoDebloat` to skip, already-gone parts just log and continue). Telnet client intentionally kept (old bench gear/scripts may still call it).

## Kept + fixed for LTSC
| File | Fix |
|---|---|
| `PowerShell/profile` | UTF-8 + history-search arrows, eza aliases, starship/zoxide init, fastfetch on interactive shells, ctrl+r/t fzf chords once the PSFzf module is present. all guarded, PS 5.1 safe |
| `Git/.gitconfig` | main branch, autocrlf, codium editor, prune, aliases. identity left blank for you |
| `Komorebi/komorebi.json` | fixed `boarder_style` typo → `border_style`, 10 workspaces, stock borders |
| `VSCodium/settings.json`, `VSCodium/keybindings.json`, `VSCodium/darkmatter-theme/` | fixed invalid JSON (`],` → `},`); deploys to `%APPDATA%\VSCodium\User\` + the Darkmatter theme folder (ctrl+alt+t terminal, ctrl+alt+b sidebar) |
| `Komorebi/whkdrc`, `File-Explorer/config.ini` (optional) | copied as-is |
| `Vesktop/settings.json` + `quickcss.css`, `qBittorrent/qbittorrent.ini`, `VLC/vlcrc`, `OBS/profiles/Recording/basic.ini`, `Helium/master_preferences` | deployed fresh-install-only, read each folder's README for the 2-minute finish. quickcss ships the system24 darkmatter theme; an untouched placeholder is upgraded on re-run, a quickcss you edited is kept |
| `SumatraPDF/SumatraPDF-settings.txt`, `WindowsTerminal/settings.json` | shipped with `-IncludeStudy`, fresh-only copy into `%LOCALAPPDATA%` |

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
- One click: double-click `Setup.cmd`. self-elevates (UAC), runs `-Unattended -IncludeStudy` (base + study pack), window stays open with the summary. flags pass through: `Setup.cmd -TweaksOnly`, `Setup.cmd -SkipApps MiKTeX`.
- Online: `powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1` (+ `-IncludeOptional` for Obsidian/Spotify, `-IncludeStudy` for the study pack, `-NoTweaks` to skip tweaks)
- Tweaks-only: same script with `-TweaksOnly` runs just the Titus tweaks (+O&O) on any live machine. No apps, no configs, no debloat. This is what the minimal ISO uses.
- Dry run: `-DryRun` walks the whole install and logs `[dry-run] would ...` for every write, download and cleanup, then stops. Nothing is touched, no bootstrap, no template regen, no phases marked done. The log and the report json still get written so you can read the plan back afterwards.
- Verify: `-Verify` reads back the key tweaks (registry values, DiagTrack/dmwappushservice, firewall, vscodium theme) and prints ok/MISS per item, exit code 1 if anything is missing. Read-only, safe to run any time including after a reboot.
- Selective: `-Only <substring>` and `-SkipApps <substring>` filter the app list by id; both take arrays. Filtering runtimes logs a warning since some apps need them, and an `-Only` run skips the bulk upgrade step.
- Retries: downloads retry 3x (BITS takes over for files >= 20 MB, verifies size), each failed app gets one free retry pass, and failures keep the apps phase open so an `-Idempotent` re-run only retries what failed. Per-app state lives in `<StateDir>\apps.json`.
- Report: every run writes `report-<stamp>.json` next to the log (mode, OS, phases with seconds, installed, failed, warning count). The log's last lines are the one-line summary.
- Drivers: universal image, so drivers go on manually per device (vendor NIC/wifi packs after first connect, or Windows Update once online).
- Offline/ISO: `ISO/Get-Offline.ps1` to pre-seed per-ID subfolders, then `-OfflineDir <path> -Unattended` (works with no winget at all). Installer waits up to 4 min for DHCP on first boot before declaring offline.
- Still manual: fonts (JetBrainsMono Nerd, Monocraft) into `Fonts/`, Helium default-browser confirm.
- Automation lab: MATLAB via campus license, USB-serial drivers (CH340/CP210x/ST-Link) via `-DriverDir <inf-folder>` or manually, vendor tools (CODESYS/TIA/Studio 5000) from their own installers.
- AI assistant: `opencode` CLI is preinstalled (`SST.opencode`) + sidebar in VSCodium. Auth is interactive: installer drops `Win-Iot-Finish.cmd` on the Public Desktop, double-click it once (`opencode auth login`). Reads anything text: `.m`, `.py`, ladder exports, docs.
- Tweaks (Titus-style, native reg, `-NoTweaks` to skip): restore point first; O&O ShutUp10++ with titus cfg, then our reg values so ours win overlaps; telemetry 0 (Enterprise-honored), DiagTrack/dmwappushservice disabled, 10 services to Manual (maps/xbox/retail/wallet/insider/CDP); updates = notify before download + no auto-reboot + no driver pushes (Win10 is cumulative so security-only split is impossible - LTSC + notify is the sane equivalent); Delivery Optimization off; silent BitLocker auto-encryption blocked; location off; WPBT execution off; smb1/llmnr/netbios off; remote assistance off; lsass protected; wdigest off; guest off; firewall+defender on; Bing/Cortana/consumer apps/GameDVR/taskbar-feeds (Win10 Widgets stand-in)/store-suggestions/error-reporting/USB-autorun off; extensions shown; This PC default; folder-type auto-discovery off; long paths on; temp files + disk cleanup; hibernate off; laptops keep the balanced power plan, desktops get ultimate/high perf (system type first, battery count as fallback); battery manners ported from the linux box: screen off 3/10 min, sleep 30 min on battery, never on ac, lid suspends on battery only, ThinkPad charge cap 80/75 via lenovo's own chargethreshold.exe (signature-checked, lenovo hardware only, `-SkipBatteryCap` to skip); autostart-delay off; `-Fixes` repairs dns/winsock/update stack on demand. Taskbar tuned with plain settings: small icons, never-combine labels, seconds clock, tray all out, junk buttons gone, classic mixer + alt-tab, no shake, stock colors, fast menus, numlock, verbose boot. Win11 extras (classic right-click menu, widgets/chat buttons, Copilot/Recall off) apply on 11 only; right-click End Task and start-menu layout still skipped (no native lever). True blur styling, middle-click actions and scroll-volume need a hooking engine and are out of scope. Also: background apps off, IPv4 preferred (full IPv6 kill breaks things, skipped), chosen DNS (`-Dns`, Cloudflare default) on live adapters, toasts + notification center off, best-performance base with ClearType, shadows and content-dragging kept, animations/peek off, fast key repeat, storage sense off, OneDrive gone, reserved storage off, teredo off, RTC in UTC, inking/typing AI leftovers off, dark mode on (taskbar + apps), world formats en-001, verbose bluescreens, svchost split matched to ram, defender exclusions for lab folders that exist. `-GamingTweaks` adds HAGS (win10 + a wddm 2.7 driver, reboot to take) and pins priority separation to the desktop default.
- Runtimes install FIRST via winget: full VC++ stack 2005→2022 (x86+x64, old vendor tools need the ancient ones), .NET 8 Desktop Runtime, .NET Framework 3.5 + DirectPlay features enabled. .NET 4.8 is already in-box on both LTSC builds.

## Verify
- `komorebic state`, `whkd --version`
- No `applications.json` needed: the old `app_specific_configuration_path` key
  hard-crashed Komorebi when the file was missing, so it was removed. Float
  rules now go inline in `komorebi.json` as `floating_applications`
  (`{"kind":"Exe","id":"notepad.exe","matching_strategy":"Equals"}` style).
