# ventoy drop-in

rufus path needs nothing. ventoy skips $OEM$, so it needs this folder.

## use
1. copy the built iso anywhere on the ventoy stick.
2. copy this `ventoy` folder to the stick root (stick ends up with
   `/ventoy/ventoy.json` and `/ventoy/script/Win-Iot-unattended.xml`).
3. boot the iso. install runs unattended, no menu.

## notes
- the template is a copy of `ISO/autounattend.xml`. change one, change both.
- the payload rides inside install.wim (`-BakeToWim`), so C:\Setup is there
  no matter the media. no net on first boot? seed ISO/Offline before
  baking, or tether the phone when the log asks.
