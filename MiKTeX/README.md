# MiKTeX

`-IncludeStudy` installs `MiKTeX.MiKTeX`. first run pops the setup wizard,
let it finish. when it asks about "install missing packages on the fly",
answer Yes, that setting is the whole point of MiKTeX.

- build a doc: `latexmk -pdf file.tex` (latexmk ships with MiKTeX)
- VSCodium builds through LaTeX Workshop, installed and pointed at SumatraPDF
  by the study pack
- packages download on demand, keep the box online the first weeks. offline
  days: `miktex packages install <name>` while there is still net
- wizard dismissed by accident? run `miktex-console` from the start menu and
  hit "Check for updates" once
