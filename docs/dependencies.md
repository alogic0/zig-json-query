# Pinned source dependencies

`build.zig.zon` downloads these sources through GitHub `git+https` URLs with full
commit IDs after `#`. Zig verifies their package content hashes. Dependency
versions are unchanged; regex and package-version retain their original commits and hashes.
Test support uses the published repository history with identical helper sources
and a separately downloaded process dependency.

| Package | Version | Source revision |
| --- | --- | --- |
| [zig-regex](https://github.com/alogic0/zig-regex) | 0.2.0 | `65e304effed8e58e5ca09a39104f8c24e28fc312` |
| [zig-test-support](https://github.com/alogic0/zig-test-support) | 0.2.0 | `5bb89e9cc406a1e2a0232520abec71a9ed4f91d7` |
| [zig-package-version](https://github.com/alogic0/zig-package-version) | 0.1.0 | `3b35ef146e0308b9aa0f61f27e95ae8c7f143a15` |

A fresh checkout or extracted source package needs network access for the first
download. Later builds reuse Zig's package cache. No sibling checkout or local
dependency archive is required. Keep the full commit IDs and content hashes
together when updating a dependency; verify the provider and consumer checks.
Git URLs also avoid an observed Zig 0.17 cache-extraction failure with nested
directories in GitHub archive downloads.

`zig build verify-dist` checks the extracted source and a separate consumer with
empty package/build caches, including fresh remote dependency downloads.

The dependencies retain their original licenses and notices:

- Regex includes its MIT LICENSE, extraction NOTICE and UNICODE-LICENSE for
  generated Unicode tables, including their original copyright notices.
- Test support includes its MIT LICENSE and NOTICE. Its manifest separately
  downloads zig-process 0.6.1 from commit
  `e9fcfccecc84f44a362b12de1bee78258b1e811f`, with a Zig content hash and the
  process package's own MIT license and provenance.
- Package-version includes its MIT LICENSE and extraction NOTICE. Its shared
  CLI owns version validation, preflight and atomic updates; this project owns
  `tools/versions.json` and the bump policy in `AGENTS.md`.

The earlier local archive checksums and qualification records remain in Git
history and frozen evidence. New profiling/qualification reports pin
`build.zig.zon` and this provenance note alongside the implementation sources.
