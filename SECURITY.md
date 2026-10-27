# Security policy

## Supported versions

Only the latest release receives fixes. Please update before reporting.

## Reporting a vulnerability

Report privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**
(https://github.com/Yabuku-xD/BetterSpotlight/security/advisories/new). Do not open a public issue.

Include the app version, macOS version, what an attacker could do and the steps to reproduce.

We acknowledge reports within 7 days and keep you updated until a fix ships. We credit reporters in the release
notes unless you ask us not to.

## Scope

In scope:

- The index files in `~/Library/Application Support/BetterSpotlight` (what is stored and who can read it).
- Content extraction of untrusted files (documents, archives, images, audio and video).
- Model download integrity: the pinned Hugging Face revision, the size and SHA-256 checks and the import path.
- File actions from the panel (open, open with, reveal in Finder, Quick Look, copy path or text).
- Use of macOS privacy permissions (Full Disk Access, folder access, speech recognition).

Out of scope: issues that need an attacker who already runs code as your user, and the unsigned-build Gatekeeper
prompt, which is expected until the app has a Developer ID.
