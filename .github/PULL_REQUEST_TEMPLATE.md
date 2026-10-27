## Summary

<!-- What changes and why, in a few sentences. -->

## Issue

<!-- Closes #123, or "none". -->

## Test plan

<!-- What you ran and what you checked by hand. -->

## Performance

<!-- Required when the change touches search, indexing or the keystroke path (SearchView, Rows, SearchModel,
     HunchCore/Search, HunchCore/Index). Paste the full output of `Scripts/perf-gate.sh` on a release build. -->

## Screenshots

<!-- Required for UI changes: before and after, Light and Dark. -->

## Checklist

- [ ] `Scripts/test.sh` passes
- [ ] `swift format lint --strict -r Sources Tests` passes
- [ ] No `*.gguf`, model or other files over 1 MB added
- [ ] No code pasted from AGPL/GPL projects
- [ ] THIRD_PARTY_NOTICES.md updated if a dependency or adapted code changed
- [ ] CHANGELOG.md updated under "Unreleased" for user-visible changes
