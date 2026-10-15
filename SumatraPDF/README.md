# SumatraPDF

`-IncludeStudy` installs it (`SumatraPDF.SumatraPDF`) and drops
`SumatraPDF-settings.txt` into `%LOCALAPPDATA%\SumatraPDF\` on a fresh
install only. if the PDF app already ran, our file loses. re-run with
`-ConfigsOnly` to stamp it over anyway.

What the shipped settings do:
- dark chrome, document pages stay paper-white
- continuous scroll, fit width
- toolbar hidden (F9 shows the menu bar, Alt peeks at it)
- synctex on: Ctrl+click in the PDF jumps back to the matching line in
  VSCodium. needs `codium` on PATH, edit `InverseSearchCmdLine` here if it
  is not
- annotation palette: warm highlight, green underline, red squiggle, orange
  strikeout

forward search (editor -> PDF) is LaTeX Workshop's half, already pointed at
SumatraPDF in `VSCodium/settings.json`. if SumatraPDF lives somewhere else on
your box, fix the two paths there.
