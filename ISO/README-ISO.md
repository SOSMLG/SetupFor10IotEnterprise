# ISO recipe (iotenterprise10.iso)

## what the base is
Win10 IoT LTSC 21H2 run through tiny10 maker. 4.55GB iso, single `install.wim`
(3.9GB), stock boot files, tiny10 autounattend (OOBE skips, auto index 1,
compact install). AppX is gone, so winget is dead on arrival. that's why the
installer goes staged files -> choco -> github releases instead.

honest limits: tiny10-style trims can break cumulative updates later, and no
recipe fixes that from here. if KBs start failing, rebuild from a stock IoT
LTSC iso with conservative removals instead of stripping deeper.

## layout
- `autounattend.xml` - merged answer file. tiny10 base + ThisPc admin (blank),
  one auto-logon, FirstLogon hook. replaces the root one at build time.
- `autounattend-firstlogon.xml` - minimal snippet version of just the hook,
  for pasting into a generator-built file instead.
- `FirstBoot.ps1` - powershell first-boot entry, called by autounattend. registers
  a one-shot task 2 min out so logon finishes in seconds, then the installer
  runs detached with a live window. `-Now` runs it immediately.
- `FirstLogon.cmd` - manual double-click wrapper around FirstBoot.ps1 (a bare
  .ps1 double-click just opens notepad).
- `StartLayout.xml` + `SetupComplete.cmd` - blank start tiles, applied as SYSTEM
  before first logon (tile wall gone, app list stays). needs no net.
- `Get-Offline.ps1` - seeds `Offline/` on a normal pc with winget. `-GapsOnly`
  fetches just helium + runtimes (everything else comes over net now).
- `Offline/` - gap cache, gitignored. built by Get-Offline, staged by Build.
- `build/` - extracted iso working copy, gitignored. `-ReuseBuild` skips re-extract.
- `Build-Iso.ps1` - extract, stage repo to `sources\$OEM$\$1\Setup` (= C:\Setup),
  stage Offline, swap autounattend, rebuild with oscdimg.

## build
1. `Get-Offline.ps1` full seed on an online pc ships everything (7zip, vlc,
   helium, runtimes) inside the iso for offline installs. `-GapsOnly` for a
   slim online-only build. drop `Offline/` here either way.
2. oscdimg: ADK Deployment Tools on PATH, or pass `-OscdimgPath`. no admin
   around? fetch the ADK layout (`adksetup /quiet /layout <dir>`, full pull,
   no /features allowed) and lift `oscdimg.exe` out of the Deployment Tools
   cab into `%TEMP%\adk-tools` - the script looks there on its own.
3. `powershell -ExecutionPolicy Bypass -File ISO\Build-Iso.ps1`
4. burn the dated iso out with rufus, boot it.

first boot: auto-logon as ThisPc, `C:\Setup\ISO\FirstLogon.cmd` installs apps
(choco + github, staged gaps), tweaks, configs, autostart. reboot when the log
says so, then double-click `Win10IoT-Finish.cmd` on the desktop.

## notes
- drivers stay manual per device (universal image), or point `-DriverDir` at
  extracted vendor infs (ch340/cp210x/st-link) and the installer stages them
  via pnputil. optional: dism `/Add-Driver` nic packs into
  `build\sources\install.wim` before rebuild.
- audit mode (`ctrl+shift+f3` at OOBE) still works for hand-installing vendor
  tools (matlab, codesys/tia) before sysprep, but the FirstLogon hook fires on
  the audit boot too. skip it there or let it run, your call.
- ventoy: boots the rebuilt iso fine, but $OEM$ only applies from real media
  layout. prefer rufus for the final stick.
