# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-28

First release of Hunch. Earlier test builds (1.0.1 to 1.1.0) are folded into this release; their index, model
and settings move over on first launch.

### Added

- Launcher panel for apps, files, folders and System Settings panes, opened with a global shortcut (⌥Space by
  default). Settings panes are found by their sidebar names and topics ("login items", "battery", "wi-fi") and open
  directly.
- With an empty search, the list shows Favorites, Recents and every app in the Applications folders A to Z.
- Content search: text in documents, text in images (OCR), frames in videos and speech in audio and video.
- Optional meaning search for text and images with EmbeddingGemma 2 (Q8_0, 865 MB), downloaded on request into
  `~/.hunch/models` with resume and SHA-256 verification. The models run in background helpers that exit when idle
  (text after 5 minutes, images after 2), so the app itself stays at about 68 MB.
- Filters: `in:`, `name:`, `ext:`, `kind:` (also a file type, `kind:pdf`) and
  `modified:today|yesterday|week|month|year`.
- Tab on a folder searches inside it (`in:` the folder); ⇧Tab goes up one folder. Tab on any other row narrows the
  list to that kind of result.
- What you open after typing a query ranks higher the next time you type that query, or one that extends or
  shortens it. At most 256 queries are kept, in memory and in the index.
- Actions (⌘K): Open, Open With, Show in Finder, Quick Look, Copy Path, pins and recents. Hold ⌥ for Force Quit
  (also ⌃⌥⇧Q), Copy File (also ⌥⇧⌘C), Get Info (also ⌘I), Share and Move to Trash (also ⌘⌫). Folders get Open in
  Terminal: the terminal that is running, else Ghostty, iTerm2, Warp or WezTerm when installed, else Terminal.
  Drag a result out of the panel into another app.
- Quiet automatic updates from GitHub Releases: a check at launch when the last one is a day old, then once a day
  at a time macOS picks. A newer version downloads, is verified against `SHA256SUMS.txt` and its code signature,
  and installs and relaunches only when no Hunch window is open and the Mac has had no input for a minute. Index,
  model and settings are kept. Settings › About can check by hand or turn updates off.
- Menu bar item, onboarding, Settings (General, Search, Index, About) and a standard app menu. The Welcome Guide
  and Settings open centred on the screen under the pointer and can be moved from there.
- Apps-only default index scope: folders such as Desktop, Documents and Downloads are added by choice.
- Everything Hunch stores lives in `~/.hunch`: the index in `~/.hunch/index`, the model in `~/.hunch/models`.
- `Scripts/quant-eval.py` and `hunch-bench --embed-eval` measure a GGUF quantization against BF16.

### Security

- Files that look like secrets are indexed by name only.
- Network access only for the model download you start, the update check and links you click.

[1.0.0]: https://github.com/Yabuku-xD/Hunch/releases/tag/v1.0.0
