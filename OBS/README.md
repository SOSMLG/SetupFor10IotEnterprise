# OBS
- Recording profile lives in `%APPDATA%\obs-studio\basic\profiles\Recording\`
  on fresh installs (1080p60, MKV, high quality x264 - MKV survives crashes,
  remux to MP4 via File menu).
  NVIDIA in the box? Settings > Output > Encoder > NVENC H.264.
- Theme: stock (Settings > General > Theme). Ships untouched.
- First scene (2 clicks): Sources + > Display Capture, Sources + > Audio
  Input Capture (your mic). ws8 (`Win+8`).
- Plugin worth having: Source Record (exeldro, obsproject forum resources).
  Adds a filter that records one source cleanly while the main scene does
  its thing - great for cutting lectures later. Grab the build matching
  your OBS version, drop it in, restart OBS.
- Quality: this profile uses Simple mode (x264, MKV). When you outgrow it:
  switch Output to Advanced, encoder NVENC H.264 (or x264 if no NVIDIA),
  rate control CQP/CQ around 20-22 for 1080p60. CBR is for streaming, not
  recording. Audio: check 48 kHz / 160+ Kbps in Settings > Audio.
