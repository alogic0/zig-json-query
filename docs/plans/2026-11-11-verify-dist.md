# Automated standalone-package qualification

Status: authorized implementation in progress, starting from jqz 0.26.2.

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
2. [ ] Implement the Zig verifier and `verify-dist` build target:
   - Add shared payload/manifest validation, archive reproducibility/content
     checks, dependency checksums and safe output/workspace handling.
   - Add source/corpus/consumer orchestration, checked command transitions,
     isolated environments/quarantine, retained artifacts/logs and JSON status.
   - Add meaningful fixtures for malformed/escaping/duplicate/link archives,
     payload/hash drift, invalid output/cleanup ownership, bad test/replay
     results and an isolation failure that must prevent consumer launch.
   - Run native Debug build/tests and focused checks. Commit the feature with
     its synchronized version markers before the full real qualification.
3. [ ] Run `zig build verify-dist` end to end on the feature snapshot. Require
   byte-identical archives, complete extracted-file/dependency checks, all source
   tests, all 45 corpus cases and eight consumer checks with no source-cache
   reuse. Inspect machine-readable evidence, raw logs and cleanup. If a failure
   exposes a bug, fix/test/version/commit it separately and qualify that fix.
4. [ ] Document usage, failure behavior and the frozen snapshot/result boundary.
   Preserve the automated evidence/checkpoint without rebuilding an archive to
   contain its own hash. Verify hashes, links and diff, mark this plan complete
   and commit the final evidence/documentation slice. Keep runtime language
   behavior and historical checkpoints unchanged.

## Completion

One explicit build command performs the previously manual source/consumer
qualification and leaves inspectable evidence. Every required check is executed
with the intended native Debug configuration. Failures are reported and cannot
advance dependent stages or leave a false successful result; owned temporary
files are cleaned safely. The command also works without relying on an existing
checkout dependency cache or tracked-file list.
