# Typst

`-IncludeStudy` installs `Typst.Typst` (the cli) and the tinymist extension
in VSCodium.

- compile: `typst compile file.typ`, add `-w` to watch and rebuild
- VSCodium: open a .typ, tinymist does the live preview, and PDF export on
  save is already on (`tinymist.exportPdf` in the VSCodium settings)
- templates from typst.app/universe are just .typ files, drop them anywhere
- fonts: typst reads system fonts, so whatever landed in `Fonts/` is there.
  boxes instead of glyphs? `typst fonts | findstr /i mono` to see what it has
