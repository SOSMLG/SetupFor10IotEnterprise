# Wireshark (automation lab)
Config is UI-driven:
- Dark follows the Windows app theme (Settings > Personalization > Colors >
  Choose your app mode > Dark).
- Font: Edit > Preferences > Appearance > Text font > JetBrainsMono Nerd Font.
- Modbus: Analyze > Enabled Protocols > make sure `modbus` is on; capture
  filter `port 502` for Modbus/TCP to a PLC.
- Capture needs Npcap (bundled in the installer - keep it checked) and
  admin rights. USB-serial sniffing is NOT Wireshark's job - use a serial
  console for that (MATLAB serialport, pyserial) or a hardware serial tap.
