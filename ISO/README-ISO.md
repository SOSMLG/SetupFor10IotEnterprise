# ISO recipe (iotenterprise10.iso)

## what the base is
Win10 IoT LTSC 21H2 run through tiny10 maker (in use here, stock iso
could not be fetched). 4.55GB iso, single `install.wim`
(3.9GB), stock boot files, tiny10 autounattend (OOBE skips, auto index 1,
compact install). AppX is gone, so winget is dead on arrival. that's why the
installer goes staged files -> choco -> github releases instead.

honest limits: tiny10-style trims can break cumulative updates later, and no
recipe fixes that from here. if KBs start failing, rebuild from a stock IoT
LTSC iso with conservative removals instead of stripping deeper.

## layout
- `autounattend.xml` - merged answer file. tiny10 base + My Pc admin (blank),
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
3. `powershell -ExecutionPolicy Bypass -File ISO\Build-Iso.ps1 -BakeToWim`
   (needs admin for the dism mount. skip the flag for a files-only build,
   but then ventoy installs won't carry the payload.)
4. burn the dated iso out with rufus, boot it. ventoy works too, see below.

first boot: auto-logon as My Pc, `C:\Setup\ISO\FirstLogon.cmd` installs apps
(choco + github, staged gaps), tweaks, configs, autostart. nic driver is
usually missing here, so plug the phone in and turn on usb tethering when
the log asks. installer waits up to 10 min for it. reboot when the log
says so, then double-click `Win-Iot-Finish.cmd` on the desktop.

## notes
- account is `My Pc` with a space. profile lands at `C:\Users\My Pc`.
  quote it everywhere (`net user "My Pc" *`), or logon breaks.
- first boot has no net until the nic driver lands. android rndis tether
  just works, iphone needs its service. tether first, real drivers after.
- drivers stay manual per device (universal image), or point `-DriverDir` at
  extracted vendor infs (ch340/cp210x/st-link) and the installer stages them
  via pnputil. optional: dism `/Add-Driver` nic packs into
  `build\sources\install.wim` before rebuild.
- audit mode (`ctrl+shift+f3` at OOBE) still works for hand-installing vendor
  tools (matlab, codesys/tia) before sysprep, but the FirstLogon hook fires on
  the audit boot too. skip it there or let it run, your call.
- ventoy: works since the `-BakeToWim` build (payload lives inside
  install.wim, ventoy never reads $OEM$). still needs one thing on the
  stick: copy the repo `ventoy/` folder to the stick root next to the iso.
  that supplies the unattend template. rufus needs none of this.
