# Vesktop
Fresh installs get `%APPDATA%\Vesktop\settings.json`. Ran it already?
Untouched, as it should be.
- Theme: system24 recolored to the darkmatter palette (near-black + coral
  `#e75353`) via `quickcss.css` (Vencord > QuickCSS > Enable, already on).
  Installer drops it into `%APPDATA%\Vesktop\settings\quickcss.css`. Re-run
  with `-ConfigsOnly` to push it again; an untouched placeholder is
  upgraded automatically, a quickcss you edited yourself is kept. the
  base sheet is fetched from the network when discord starts, so a first
  boot before you are online looks stock. reconnect, restart vesktop.
- ws5 is the comms zone (`Win+5`), same as it ever was.
- Three Vencord plugins come pre-enabled in settings.json (VolumeBooster,
  SilentTyping, ReadAllNotificationsButton), plus GameActivityToggle (hide
  the game you're playing when uni servers are watching), AnonymiseFileNames
  (scrubs upload filenames before sending), and BetterSessions (see and kill
  logged-in sessions). Unknown names are ignored, so if one got renamed
  upstream nothing breaks. Want more: settings UI lists all 170+, most are
  harmless fun.
- Screen share on Wayland tricks don't apply - Windows capture just works.
  For audio share use Discord's own screen-share dialog.
