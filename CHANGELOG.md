# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The model runs in a helper process (`hunch-embedder`) that exits after 5 idle minutes. The app stays at about
  68 MB; before, unloading the model left 50–110 MB behind in the app.
- Search queries use their own small llama.cpp context; the wide indexing context is created only when files are
  indexed. Memory while searching by meaning: 289 MB in total, was 355 MB.
- Row icons and content previews share one tile size (32 pt, 28 pt on small screens); group glyphs sit centred on
  their first row.
- The model helper ships as `Contents/Helpers/Hunch Helper.app`, a background-only bundle: Activity Monitor shows
  it as "Hunch Helper" with Hunch's icon, and it never appears as an app of its own.
- App icon: continuous-corner (superellipse) tile, a deeper glass orb with a specular highlight and lit rim, and a
  warm caustic below it.
- The menu bar item has an autosave name, so its position is kept across launches.

### Added

- `Scripts/quant-eval.py` and `hunch-bench --embed-eval`: measure a GGUF quantization against BF16. Q8_0 stays the
  default; no smaller EmbeddingGemma 2 quant keeps the top-10 results (see README FAQ).

## [1.1.0] - 2026-10-27

### Changed

- New name and icon: BetterSpotlight is now **Hunch**. The app, bundle id (`app.hunch.Hunch`), data folder
  (`~/Library/Application Support/Hunch`) and repository moved; GitHub redirects the old URL.
- The menu bar item uses the new mark (an orb with a glint) instead of a magnifier.

### Fixed

- Updating from 1.0.0 keeps the index, the downloaded model and settings: they move to the new name on first launch.
- `IndexCoordinatorTests` no longer fail when FSEvents delivery is slow on a busy machine.
- The perf gate's hover checks measured the cost of showing the panel, not of hovering; they now compare the shown
  panel with and without a hovered row.

## [1.0.0] - 2026-10-27

### Added

- Launcher panel for apps, files and folders, opened with a global shortcut.
- Content search: text in documents, text in images (OCR), frames in videos and speech in audio and video.
- Optional meaning search for text and images with EmbeddingGemma 2, downloaded on request (865 MB) with resume,
  SHA-256 verification and reuse of an existing DigUp or Hugging Face copy.
- `in:`, `name:`, `ext:` and `kind:` filters, quick actions (Open With, Show in Finder, Quick Look, Copy Path), pins and recents.
- Onboarding, Settings (General, Search, Index, About) and a standard app menu.
- Apps-only default index scope: folders such as Desktop, Documents and Downloads are added by choice.

### Security

- Files that look like secrets are indexed by name only.
- No network access except the model download you start and links you click.

[Unreleased]: https://github.com/Yabuku-xD/Hunch/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Yabuku-xD/Hunch/releases/tag/v1.0.0
