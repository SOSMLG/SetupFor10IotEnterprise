# Zotero

`-IncludeStudy` installs `DigitalScholar.Zotero`. no config file ships here,
the first-run wizard is fine as-is. two things worth five minutes after:

- Better BibTeX: grab the xpi from retorque.re/zotero-better-bibtex and add
  it via Tools -> Add-ons -> gear -> Install Add-on From File. stable
  citation keys that survive edits, latex and typst both eat them.
- sync: the free tier's 300MB will not fit a thesis. either link a WebDAV
  folder in Settings -> Sync, or just keep a plain backup of
  `%USERPROFILE%\Zotero` in your own cloud.

the browser connector is a normal chromium extension, so Helium takes it
from the Zotero site while logged in.
