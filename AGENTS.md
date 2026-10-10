# AGENTS.md - notes for any coding agent working in this folder

## What this is
Slim Win10 IoT 21H2 (19044) setup: PowerShell base, Komorebi + whkd,
Helium, VSCodium, stock taskbar. Red and black theme everywhere.
Unattended installer: `Install-Win10-IoT-21H2.ps1` (`-TweaksOnly` for
tweaks-only runs). Custom ISO recipe in `ISO/README-ISO.md`.

## Rules learned the hard way
- Komorebi `border_colours` is British spelling. `boarder_*` was a real
  bug here once. Schema: `.../LGUG2Z/komorebi/v0.1.39/schema.json`.
- Never add `app_specific_configuration_path` without shipping the file.
  Komorebi hard-crashes on a missing path (os error 2). Float rules go
  inline as `floating_applications` instead.
- Native exes (DISM, powercfg, installers) don't throw in PowerShell.
  Always check `$LASTEXITCODE`. try/catch alone lies.
- `winget download` filenames embed the installer tech
  (`_<scope>_<arch>_<tech>_<lang>.<ext>`). Read the tech for silent flags,
  don't guess: `_burn_` = /install /quiet, `_exe_` legacy redists = /q,
  `_wix_` = .msi, `_inno_` = /VERYSILENT, `_nullsoft_` = /S.
- Unknown keys in vlcrc/qbittorrent.ini/OBS basic.ini are ignored, so
  best-effort keys are safe there. Unknown JSON keys in komorebi.json
  are tolerated too (observed on 0.1.41), but prefer schema-known keys.
- Vencord ignores unknown plugin names in settings.json. Still, only add
  plugin names verified against vencord.dev/plugins.
- Voice: comments and logs read like one tired human. Short, lowercase
  asides, no em-dashes, no buzzwords, no triplets. Never "improve" wording
  in a way that touches logic. Run `check_balance.py` after every edit:
  `python3 <temp>/check_balance.py Install-Win10-IoT-21H2.ps1`.

## Layout
- Per-app folders hold a config + short README. Fresh-install only deploys
  (`Copy-Fresh`), never overwrite a lived-in config.
- `OOSU/` bundles O&O ShutUp10++ + titus cfg (85MB, checksum-verified).
  Runs `/quiet` before our reg values so ours win overlaps.
- `ISO/`: FirstLogon.cmd, Get-Offline.ps1 (keep its ID list in sync with
  the installer's), Offline/ cache (gitignored), build/ working copy
  (gitignored), merged autounattend.xml (ThisPc admin + FirstLogon).
- `.gitignore` excludes `*.iso`, `ISO/build/`, `ISO/Offline/`. No secrets
  in the tree: blank passwords, empty API keys.
