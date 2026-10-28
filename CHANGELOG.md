# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Move to Trash (⌘⌫, or ⌥ on the Exclude action), Get Info (⌘I, or ⌥ on Show in Finder) and Share (⌥ on Open With).
- Open in Terminal for folders, in Quick Look's place in ⌘K. It uses the terminal that is running, else Ghostty,
  iTerm2, Warp or WezTerm when installed, else Terminal.
- Tab on a folder searches inside it (`in:` the folder); ⇧Tab goes up one folder.
- What you open after typing a query ranks higher the next time you type that query, or one that extends or
  shortens it. At most 256 queries are kept, in memory and in the index database.

### Changed

- Settings opens centred on the screen under the pointer, like the Welcome Guide, and a taller pane no longer grows
  past the bottom of the screen.

- Name rows are 4 pt taller (44 pt; 40 pt on small screens), so a row next to a cut or the selected row no longer
  sits against the glass edge.

## [1.1.0] - 2026-10-27

### Added

- With an empty search, the list shows every app in the Applications folders A to Z under Favorites and Recents.

### Fixed

- On 1x displays (most non-Apple monitors), the panel's corners no longer look stepped. A 1 pt antialiased
  hairline now covers the glass rim there; Retina screens are unchanged.

- Update and Relaunch opens the new version again. Hunch quit and stayed closed: Launch Services still listed the
  old process for a moment and sent the reopen to it instead of launching.

## [1.0.3] - 2026-10-27

### Changed

- The model helper frees its indexing buffers 30 seconds after the last indexing batch and keeps only the small
  search buffers: 327 → 222 MB between indexing bursts. The next batch rebuilds them in about 1 second.

## [1.0.2] - 2026-10-27

### Fixed

- Opening Hunch brings Settings to the front on the first click; it opened behind the active app before.

## [1.0.1] - 2026-10-27

### Fixed

- The model helper no longer grows while indexing. Every request it read stayed in memory (1.1 GB after an hour);
  it now stays flat.
- The image model (EmbeddingGemma 2 with its vision projector) runs in its own helper process, closed after 2 idle
  minutes, instead of inside the app, where about 900 MB stayed after it closed.
- Opening Hunch again while the Welcome Guide is open brings the guide forward instead of opening Settings.

### Changed

- Document embedding uses Metal flash attention and 1024-token batches: about 70 MB less while indexing at the same
  speed, with the same vectors.

## [1.0.0] - 2026-10-27

First release of Hunch.

### Added

- Launcher panel for apps, files, folders and System Settings panes, opened with a global shortcut (⌥Space by
  default). Settings panes are found by their sidebar names and topics ("login items", "battery", "wi-fi") and open
  directly.
- Content search: text in documents, text in images (OCR), frames in videos and speech in audio and video.
- Optional meaning search for text and images with EmbeddingGemma 2 (Q8_0, 865 MB), downloaded on request into
  `~/.hunch/models` with resume and SHA-256 verification. The model runs in a background helper
  (`Contents/Helpers/Hunch Helper.app`) that exits after 5 idle minutes, so the app itself stays at about 68 MB.
- Filters: `in:`, `name:`, `ext:`, `kind:` (also a file type, `kind:pdf`) and
  `modified:today|yesterday|week|month|year`.
- Actions (⌘K): Open, Open With, Show in Finder, Quick Look, Copy Path, pins and recents. Hold ⌥ for Force Quit
  (also ⌃⌥⇧Q) and Copy File (also ⌥⇧⌘C). Drag a result out of the panel into another app.
- In-app updates: Settings › About and the menu bar item check GitHub Releases, verify the download against
  `SHA256SUMS.txt` and its code signature, replace the app and relaunch. Index, model and settings are kept. An
  automatic check runs at most once a day at launch and can be turned off.
- Menu bar item, onboarding, Settings (General, Search, Index, About) and a standard app menu.
- Apps-only default index scope: folders such as Desktop, Documents and Downloads are added by choice.
- `Scripts/quant-eval.py` and `hunch-bench --embed-eval` measure a GGUF quantization against BF16.

### Security

- Files that look like secrets are indexed by name only.
- Network access only for the model download you start, the update check and links you click.

[1.0.2]: https://github.com/Yabuku-xD/Hunch/releases/tag/v1.0.2
[1.0.1]: https://github.com/Yabuku-xD/Hunch/releases/tag/v1.0.1
[1.0.0]: https://github.com/Yabuku-xD/Hunch/releases/tag/v1.0.0
