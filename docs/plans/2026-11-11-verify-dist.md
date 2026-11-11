# Automated standalone-package qualification

Status: complete. jqz 0.27.1 passes automated standalone qualification and the
intentional timeout check in native x86_64 Linux Debug.

## Objective

Replace the manual steps from the completed
[standalone-package plan](2026-11-11-standalone-package.md) with
`zig build verify-dist`. Reuse the pinned test-support/process helpers and
existing package, corpus and consumer. New implementation is Zig; no additional
dependency or tool is required beyond the existing Zig/Git/GNU utilities, jq and
GNU time. Validation remains native x86_64 Linux Debug only.

## Behavior and contracts

- Share the archive roots/exclusions between `dist` and the verifier. Fingerprint
  the complete payload before/after packaging and qualification; reject source
  drift, missing/extra members, malformed paths, duplicates, links/special files
  and archive content mismatches before extraction.
- Build two archives and require identical bytes. Retain the qualified copy,
  complete manifest and exact tool identities in a unique output directory.
- Extract into an exclusively owned workspace outside the checkout. Initialize
  independent source/consumer Git repositories. Use distinct, initially empty
  local/global caches and absent relative package directories.
- Run source build/tests and the one-repetition frozen corpus replay. Discover
  actual successful test counts while requiring the existing checks; do not
  hard-code a total that prevents future meaningful tests. Check every replay
  case/status and source fingerprint, not merely child exit zero.
- Copy the consumer's build/main/manifest from the archive; adjust only its
  dependency path. Quarantine every source artifact path, including a default
  `.zig-cache` left by tests. Verify isolation before starting the consumer and
  after its independent build. Run all existing consumer checks.
- Only the explicit `verify-dist` target runs full packaging qualification.
  Ordinary `zig build test` runs focused verifier fixture/unit checks and must
  never recursively launch full qualification from an extracted source.
- Check command outcomes, deadlines and capture/cleanup errors before dependent
  work. Write bounded logs and JSON evidence for both successful and failed
  runs. A failed run exits nonzero and cannot publish a successful status.
- Keep generated output outside archive payload roots, with source/version/tool
  fingerprints and an explicit snapshot boundary. Default output is under
  `zig-out/verify-dist`; reject unsafe output paths before modifying them.
- Cleanup only the freshly owned workspace, never follows directory symlinks,
  and refuses an unowned/mismatched root. Remove files with plain `rm` (no flags)
  and empty directories with `rmdir`. Persistent evidence/logs stay outside it.
  Cleanup failure remains visible and prevents a verified result.
- Preserve previous evidence and corpus expectations. Add no query syntax,
  architecture/build-mode matrix, provider modifications or network publication.

## Verified slices

Each verified slice is committed before starting the next. Before a feature/fix
commit, run `zig build version`, keep major 0 and use
`zig build version -- set VERSION`; include all updated markers. This new build
capability receives a minor increment; subsequent compatible fixes use patches.
Write the complete commit message to a temporary file, use `git commit -F`, and
remove that file with plain `rm` after success.

1. [x] Record this plan and inspect current packaging, command, filesystem and
   workspace APIs. Check the existing inventory, keep all dependencies pinned
   and link the plan from project/package documentation. Commit the plan.
2. [x] Implement the Zig verifier and `verify-dist` build target:
   - Add shared payload/manifest validation, archive reproducibility/content
     checks, dependency checksums and safe output/workspace handling.
   - Add source/corpus/consumer orchestration, checked command transitions,
     isolated environments/quarantine, retained artifacts/logs and JSON status.
   - Add meaningful fixtures for malformed/escaping/duplicate/link archives,
     payload/hash drift, invalid output/cleanup ownership, bad test/replay
     results and an isolation failure that must prevent consumer launch.
   - Run native Debug build/tests and focused checks. Commit the feature with
     its synchronized version markers before the full real qualification.
3. [x] Run `zig build verify-dist` end to end on the feature snapshot. Require
   byte-identical archives, complete extracted-file/dependency checks, all source
   tests, all 45 corpus cases and eight consumer checks with no source-cache
   reuse. Inspect machine-readable evidence, raw logs and cleanup. If a failure
   exposes a bug, fix/test/version/commit it separately and qualify that fix.
4. [x] Document usage, failure behavior and the frozen snapshot/result boundary.
   Preserve the automated evidence/checkpoint without rebuilding an archive to
   contain its own hash. Verify hashes, links and diff, mark this plan complete
   and commit the final evidence/documentation slice. Keep runtime language
   behavior and historical checkpoints unchanged.

## Completion

Feature checks: native `zig build`, `zig build test --summary all` (227 tests),
seven focused verifier checks, CLI help compilation, synchronized version markers
and formatting/diff checks passed. The feature snapshot is committed before the
explicit full qualification below; these focused checks make no standalone
qualification claim by themselves.

The first real 0.27.0 run exposed borrowed command-argument arrays in retained
evidence: serialization aborted after archive validation. That run is excluded.
Its last progress/logs and an explicit failure/recovery note remain under
`zig-out/verify-dist/run-9f27a3371026418bc5de01c9`; the marked workspace was removed
with plain `rm`/`rmdir`. The separate 0.27.1 fix copies each argument and its array.
A regression mutates both caller buffers before serializing the retained record.
Native build/all 228 tests, eight verifier checks, help, version and formatting
checks pass before repeating full qualification.

The complete 0.27.1 run qualifies clean snapshot
`c5f8fa415e5d7a5376fa0b767c2f3e4b3b6cde7b`: all 15 stages/41 commands succeed,
228 source checks and eight consumer checks pass, and the replay validates all
45 cases (30 observed translations, ten probes, 68 smoke samples). All five
source artifact paths are quarantined and remain absent after the consumer;
the payload is unchanged, the two archives are byte-identical, and workspace
cleanup succeeds. Archive SHA-256:
`eec2ae0179be88b872a3a8222c3191155afab515b36f02e101cfc59d0d3f38e2`.
The [generated evidence](../qualification/2026-11-11-verify-dist-evidence.json),
[complete payload manifest](../qualification/2026-11-11-verify-dist-payload.json),
[replay](../qualification/2026-11-11-verify-dist-replay.json) and selected raw logs
are preserved unchanged after freezing that archive.

A separate [intentional timeout](../qualification/2026-11-11-verify-dist-timeout.json)
uses a 100 ms per-command deadline: packaging times out, the runner exits nonzero,
the consumer never starts, and cleanup succeeds. The complete passing result
uses a different report path and remains intact. Artifact/report hashes and
byte-identical copies are checked, both workspaces are absent, and the
[qualification report](../qualification/README.md) records usage, limits and the
snapshot/result boundary. No further implementation steps remain in this plan.

One explicit build command performs the previously manual source/consumer
qualification and leaves inspectable evidence. Every required check is executed
with the intended native Debug configuration. Failures are reported and cannot
advance dependent stages or leave a false successful result; owned temporary
files are cleaned safely. The command also works without relying on an existing
checkout dependency cache or tracked-file list.
