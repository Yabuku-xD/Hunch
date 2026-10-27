# Third-party notices

Hunch bundles or adapts the following third-party software. Each is used under its license, reproduced
below.

## llama.cpp and ggml (bundled framework)

`Contents/Frameworks/llama.framework` (llama, ggml with the Metal and CPU backends, and mtmd) is the official
llama.cpp release b11669 xcframework (https://github.com/ggml-org/llama.cpp/releases/tag/b11669), built from
https://github.com/ggml-org/llama.cpp and https://github.com/ggml-org/ggml. License: MIT.

The unsupported local build path (`HUNCH_LLAMA=homebrew`) links the Homebrew llama.cpp and ggml kegs instead, which pull
in libomp (LLVM OpenMP runtime, Apache-2.0 WITH LLVM-exception). Release builds do not use or bundle it.

    MIT License

    Copyright (c) 2023-2024 The ggml authors

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
    documentation files (the "Software"), to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
    to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of
    the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
    THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
    CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
    IN THE SOFTWARE.

## DigUp

https://github.com/ARahim3/DigUp, MIT License. Source files that adapt DigUp code carry the comment
`// Adapted from DigUp (MIT, github.com/ARahim3/DigUp) <file>` and are listed here.

Adapted files: none. `Sources/HunchCore/Model/ModelStore.swift` pins the same model repository, revision, file
sizes and SHA-256 digests as DigUp's `Sources/DigUpKit/ModelFiles.swift` (facts about third-party files, marked with
a source comment); its download, resume and verification code was written independently. DigUp issues/PRs informed design and test scenarios only
(DU#16 Unicode normalization, DU#49 batched embedding, DU#104 stopword highlighting, DU#139 short chunks,
DU#141/DU#153 photo folders); no DigUp source was copied.

    MIT License

    Copyright (c) ARahim3

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
    documentation files (the "Software"), to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
    to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of
    the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
    THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
    CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
    IN THE SOFTWARE.

## Tinycast

https://github.com/abue-ammar/tinycast (AGPL-3.0) was used for ideas and performance metrics only. No Tinycast code
is included.

## EmbeddingGemma 2 (downloaded at first use, not bundled)

The optional semantic search model is EmbeddingGemma 2 by Google DeepMind, in ggml-org's Q8_0 GGUF conversion
(`embeddinggemma-2-Q8_0.gguf` and `mmproj-embeddinggemma-2-Q8_0.gguf`, 864.7 MB). It is not part of this repository
or the app bundle: the app downloads it from Hugging Face only when you ask, at the pinned revision
`bfcd298762cc34d0357ece5ebdd31791a3a374d8` of https://huggingface.co/ggml-org/embeddinggemma-2-GGUF, and checks
each file's SHA-256 before use.

- Model card: https://huggingface.co/google/embeddinggemma-2
- License: Apache License 2.0 (Apache-2.0), https://www.apache.org/licenses/LICENSE-2.0
- Gemma is a trademark of Google LLC.

## SQLite and Apple frameworks

SQLite (public domain) and the Apple system frameworks are provided by macOS and are not redistributed.

## Trademarks

Not affiliated with Apple Inc. or Google LLC. Mac, macOS and Spotlight are trademarks of Apple Inc.
