# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Yabuku-xD/BetterSpotlight/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Yabuku-xD/BetterSpotlight/releases/tag/v1.0.0
