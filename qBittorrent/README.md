# qBittorrent
Fresh installs only, `%APPDATA%\qBittorrent\qbittorrent.ini`.
- Change save path: Tools > Preferences > Downloads (staged default is
  `C:/Users/Public/Downloads` - edit the ini or the UI before downloading).
- WebUI on `:8080` (admin/admin - change it: Tools > Preferences > Web UI).
- Dark look: Tools > Preferences > Behavior > dark is automatic on dark
  Windows; for a red accent grab any red/black `.qbtheme` and load it under
  Tools > Preferences > Behavior > Use custom UI theme.
- Park it on ws8 (`Win+8`) with OBS and VLC. Media corner.
- Search without browser tabs: View > check Search engine, then Search tab >
  Search plugins > Check for updates. Ships eztv, piratebay, limetorrents,
  solidtorrents and friends. Needs Python - already installed by the setup.
  Jackett shows up too but wants its API key; that means running Jackett
  itself somewhere. Skip it unless you go down that hole.
- Speed + privacy, from people who benchmark this stuff: BitTorrent tab,
  DHT and Peer Exchange ON, Local Peer Discovery OFF (unless campus LAN),
  encryption Allow (Require only if you accept fewer peers), port somewhere
  49160-65534 forwarded on your router, queue 4-6 active. Anonymous mode
  hides metadata but breaks private trackers - publics only. Disk cache:
  leave Auto unless it stutters, then try 512. Status bar: right-click it,
  show external IP, so you know what the swarm sees.
