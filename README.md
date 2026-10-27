# BetterSpotlight

A fast, private Spotlight alternative for macOS. Find any app, file or folder, and the words inside them, on your Mac,
offline.

![BetterSpotlight panel](docs/hero.png)

![CI](https://img.shields.io/badge/CI-GitHub%20Actions-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-green)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black) ![Apple silicon](https://img.shields.io/badge/arch-arm64-lightgrey)

## Features

- **Names**: apps, files and folders, ranked as you type, keyboard-first (↑/↓, ↵, ⌘↵, ⌘1–9, Tab to narrow).
- **Contents**: text inside documents (PDF, Office, RTF, plain text and code), text inside images (OCR), text and frames
  inside videos, and speech inside audio and video.
- **Meaning**: semantic matches for text and images through EmbeddingGemma 2 and its image projector, on-device.
- **Filters**: `in:Folder`, `name:`, `ext:` and `kind:` operators.
- **Actions**: open, open with, reveal in Finder, Quick Look, copy path, pin to Favorites (⌘K shows them all).
- **Liquid Glass panel**: one slab of system glass that follows Light/Dark, Increase Contrast, Reduce Transparency and
  Reduce Motion.

Out of scope on purpose: clipboard history, calculator, snippets, extensions, AI chat, window management.

## Privacy

- Everything runs on your Mac. There is no telemetry and no account.
- The only network call is the optional model download from Hugging Face, plus "Check on GitHub" in Settings → About
  if you click it.
- The index lives in `~/Library/Application Support/BetterSpotlight`. Files that look like secrets are indexed by name
  only.

## Install

1. Download `BetterSpotlight-<version>-arm64.zip` from the Releases page, open it and drag BetterSpotlight.app to
   /Applications.
2. Double-click it. macOS says it "cannot verify the developer". Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll to Security, find "BetterSpotlight was blocked", click
   **Open Anyway** and authenticate.
4. Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/BetterSpotlight.app`.

There is no paid Apple Developer ID yet; the build is ad-hoc signed and reproducible from source with
`Scripts/make-app.sh`. Because ad-hoc signatures change with every build, **Full Disk Access and Speech Recognition
grants reset after each update**. Onboarding detects this and offers to grant them again.

Permissions: Full Disk Access is optional (it widens what can be indexed); Speech Recognition is only needed for
transcripts of audio and video.

## The model (optional)

Semantic search uses EmbeddingGemma 2 by Google DeepMind (Apache-2.0), Q8_0 GGUF files from
`ggml-org/embeddinggemma-2-GGUF` on Hugging Face at a pinned revision, checked by SHA-256:

| File | Size |
|---|---|
| `embeddinggemma-2-Q8_0.gguf` (text) | 310 MB |
| `mmproj-embeddinggemma-2-Q8_0.gguf` (images) | 555 MB |

That is 865 MB in total. Onboarding offers the download; it reuses a copy already in the Hugging Face cache or in
DigUp's Models folder, and you can also choose the files by hand. Without the model, name and content search still
work.

## Build from source

Requirements: Apple silicon, macOS 26 or later, Xcode 27 or the Command Line Tools with Swift 6.4.

```sh
git clone <this repository>
cd BetterSpotlight
swift build
./Scripts/test.sh          # unit and integration tests
./Scripts/make-app.sh      # build/BetterSpotlight.app, ad-hoc signed
./Scripts/install.sh       # optional: copy it to /Applications
```

## Benchmarks

Measured on an Apple M5 Pro with 24 GB of RAM, macOS 27.2, release build, during this release's verification run
(2026-10-27). These are measurements, not targets. Panel numbers come from `Scripts/perf-gate.sh` (the app's
`--measure` mode, 20 shows and 20 typed characters per run); engine numbers come from `spot-bench` on a synthetic
corpus of 200,000 names and 100,000 vectors.

| Metric | p50 | p95 |
|---|---|---|
| Hotkey → panel on screen | 14.8–15.2 ms | 17.5–20.0 ms |
| Keystroke → first results on screen | 18.7–21.6 ms | 26.2–27.5 ms |
| Results applied → frame committed | 8.2–8.5 ms | 12.3–13.5 ms |
| Name search, 200k items | | 4.1 ms |
| Vector search, 100k vectors | | 1.9 ms |
| Query embedding | | 5.1 ms |

| Metric | Value |
|---|---|
| Idle CPU, panel hidden | 0.04 % |
| Idle memory (RSS), model not loaded | 89 MB |
| Memory with the model loaded | 634 MB |
| Crawl throughput | 39,700 items/s |
| Document chunks embedded | 779 /s |

## Comparison (as of October 2026)

| | Content search | OCR in images | Speech | Semantic | Offline | Open source | Price |
|---|---|---|---|---|---|---|---|
| macOS Spotlight | yes | yes | no | n/v | yes | no | free |
| Raycast | via Spotlight | no | no | no | n/v | no | free / paid |
| Alfred | via Spotlight | no | no | no | yes | no | free / paid |
| DigUp | yes | yes | no | yes | yes | yes (MIT) | free |
| Tinycast | no | no | no | no | yes | yes (AGPL-3.0) | free |
| BetterSpotlight | yes | yes | yes | yes | yes | yes (MIT) | free |

Feature columns only; this table makes no claims about other apps' speed. "n/v" = not verified.

## FAQ

- **Why not just Spotlight?** BetterSpotlight searches meaning as well as words, reads speech and video frames, and
  never leaves your Mac.
- **Why "Open Anyway"?** The app is not notarized (no Developer ID yet). See Install.
- **Why do permissions reset after an update?** Ad-hoc signatures change with each build, and macOS ties grants to the
  signature.
- **Does it upload my files?** No.
- **Disk and memory?** About 90 MB of memory at rest; about 630 MB while the model is loaded for indexing or a query.
  The index size depends on your files.
- **Can it reuse DigUp's or the Hugging Face cache's model?** Yes, it finds both.
- **Intel Macs?** No, Apple silicon only.
- **Uninstall?** Quit it, then delete `/Applications/BetterSpotlight.app`,
  `~/Library/Application Support/BetterSpotlight` and the app's preferences in `~/Library/Preferences`.

## Credits

- [llama.cpp / ggml](https://github.com/ggml-org/llama.cpp) (MIT) for on-device inference.
- EmbeddingGemma 2 by Google DeepMind (Apache-2.0).
- [DigUp](https://github.com/ARahim3/DigUp) (MIT): ideas and adapted code, see `THIRD_PARTY_NOTICES.md`.
- [Tinycast](https://github.com/abue-ammar/tinycast) (AGPL-3.0): ideas only, no code.

Spotlight, macOS and Apple silicon are trademarks of Apple Inc. This project is not affiliated with Apple.

## License

MIT, see [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
