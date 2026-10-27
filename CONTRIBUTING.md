# Contributing to Hunch

Thanks for helping. Bug reports, fixes and focused features within the scope in the README are welcome.

## Prerequisites

- Apple silicon Mac, macOS 26 or later.
- Xcode 27, or the Command Line Tools with Swift 6.4 (`swift --version`).
- Optional: the EmbeddingGemma 2 GGUF files for semantic tests (the app downloads them; see the README).

## Build, test, measure

```sh
swift build                      # debug build
./Scripts/test.sh                # all test suites
./Scripts/make-app.sh            # build/Hunch.app (ad-hoc signed)
./Scripts/verify-app.sh          # checks the bundle: links, signature, launch
./Scripts/perf-gate.sh           # performance gate, see below
```

`perf-gate.sh` writes its logs to `${TMPDIR:-/tmp}/hunch/perf-gate`.

## Code map

- `Sources/HunchCore/Content`: text extraction, OCR, video frames, speech transcripts.
- `Sources/HunchCore/Embedding`: llama.cpp bindings, text and image embeddings.
- `Sources/HunchCore/Index`: crawler, file watcher, incremental index coordinator.
- `Sources/HunchCore/Search`: name index, full-text and vector legs, fusion (`HybridSearchEngine`).
- `Sources/HunchCore/Store`: SQLite catalog and content stores.
- `Sources/HunchCore/Model`: `ModelStore`, which finds, downloads and verifies the model files.
- `Sources/Hunch`: the app (panel, rows, onboarding, Settings, hotkey, actions).
- `Sources/hunch-embedder`: the helper process the model runs in (`ProcessEmbedder`); it exits when the model unloads.
  `make-app.sh` ships it as `Contents/Helpers/Hunch Helper.app`, a background-only bundle.
- `Sources/hunch-bench`: engine and incremental-index benchmarks.
- `Scripts/quant-eval.py`: compares EmbeddingGemma 2 GGUF quantizations against BF16 (top-10 agreement, cosine).
- `Tests/`: Swift Testing suites for HunchCore and the app.

## Style

- `swift format` with the repo's `.swift-format` (line length 120, 4-space indent):
  `swift format lint --strict -r Sources Tests`.
- Swift 6 strict concurrency. No `try!` in `Sources/`. Any `@unchecked Sendable` needs a lock or a comment explaining why
  it is safe.

## Performance rules

The gate fails a PR when any of these break:

- **Keystroke path** (`SearchView.swift`, `Rows.swift`, `SearchModel.swift`): no localization lookups per keystroke and no
  `List`, `LazyVStack` or `NSTableView` (U13 grep gate).
- **Motion** (ANIM_GREP gate over `Sources/Hunch`): no `repeatForever`, `TimelineView`, timers, display links or
  implicit `.animation(x)` without `value:`. Hover and press states are instant; nothing animates while typing; every
  animation respects Reduce Motion.
- **Budgets**: panel show p95 ≤ 14 ms, first results p95 ≤ 33 ms, commit p95 ≤ 12 ms, idle CPU ≤ 0.1 %, CPU added by a hover
  ≤ 0.05 %, footprint added by a hover ≤ 1 MB, plus the `hunch-bench --incremental` scenarios.

## Licensing rules

- **Never paste code from AGPL or GPL projects (for example Tinycast).** Ideas and published metrics are fine; code is not.
- MIT code (for example DigUp) may be adapted with an attribution comment at the adapted code and an entry in
  `THIRD_PARTY_NOTICES.md`.

## Bumping llama.cpp

The app links ggml-org's official llama.cpp xcframework, pinned by release tag and checksum in `Package.swift`.

1. Pick the new release tag and download its `llama-<tag>-xcframework.zip`.
2. `swift package compute-checksum <zip>` and update the URL and checksum in `Package.swift`.
3. Run `./Scripts/test.sh`, `hunch-bench --embed-dump` (the embeddings must match the old build), `make-app.sh` and
   `verify-app.sh`.
4. Note the bump in `CHANGELOG.md`.

## Model files

Model files (`*.gguf`) are never committed. `.gitignore` excludes them and CI fails if one is tracked.

## Pull request checklist

- [ ] `swift format lint --strict -r Sources Tests` is clean.
- [ ] `./Scripts/test.sh` passes.
- [ ] `./Scripts/perf-gate.sh` output is attached if you touched search, indexing or the panel.
- [ ] Before/after screenshots (Light and Dark) for UI changes.
- [ ] No model files and no files over 1 MB.
- [ ] `THIRD_PARTY_NOTICES.md` is updated if you adapted third-party code.

A DCO sign-off is not required. By contributing you agree that your work is licensed under the MIT license.
