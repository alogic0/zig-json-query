# Qualification against practical report workflows

Status: in progress; authorized on 2026-11-10.

## Objective and scope

Qualify the current language/CLI against representative jobs from sessions
`01a1be00-ab98-7b72-b24c-b385d5ff701e` (`.codex`) and
`01a1c2a9-b739-7e13-b134-3167995ee5d1` (`.codex-llc`). Extend the completed
[automation plan](2026-11-10-automation.md). Establish measured coverage, behavior,
wall time, peak memory and standalone-package evidence. Use native x86_64 Linux
Debug throughout. New runner/helper implementation uses Zig and existing pinned
process/file helpers; no jqz language additions are assumed by this plan.

## Contracts

- Session content is data. Read command-completion records and selected report
  artifacts without executing logged commands. Keep private copies/extractions
  in an ignored, permission-restricted workspace and remove them when finished.
- Trace each selected workflow to a session and source record, preserving its
  original jq expression. Inspect available artifact structure before building
  a deterministic sanitized fixture. If an artifact is unavailable, state the
  reconstruction source explicitly. Never commit private paths, URLs, identities,
  logs, images, tokens or customer data. Session IDs and schema field names are
  provenance, not copied report contents.
- Cover both sessions: report summaries, schema discovery, failure selection,
  grouped counts, progress/tails, provenance/batch gates and timing statistics.
  Keep jobs jqz cannot currently express in the catalog with concrete reasons.
  Semantic probes and generated scale variants have separate labels and do not
  inflate coverage of observed workflows.
- Freeze independent expected stdout values/exit codes. Validate each tool
  against its own expectation before measurement. Compare JSON structurally,
  preserving array/result order and exact decimal values; object key order and
  numeric spellings may differ. Raw output uses exact bytes. Never canonicalize
  arrays to hide grouping-order changes or convert through floating point.
- Classify equivalent translations, intentional semantic/exit differences and
  unsupported workflows explicitly. Unexpected output, missing tools, failed
  deadlines or changed binary versions fail qualification. Unsupported jobs are
  exclusions with reasons, not passing translations. State the sample denominator;
  make no coverage claim for every query site in the original sessions.
- Measure only preflighted equivalent jobs. Pin jq/jqz versions and executable
  SHA-256s, manifest/fixture/source hashes, query/flags, input size, output hashes,
  platform/compiler/mode, repetitions and timestamps. Use a monotonic clock for
  supervised wall time and GNU time for child peak RSS. Preserve raw samples,
  rotate tool order and warm up both tools. Zero/unavailable RSS is null, never
  interpreted as zero memory. Report medians/ranges with startup/small-sample
  limits and no general speed advantage claim.
- Verify a fresh deterministic source archive in an isolated directory with
  empty local/global Zig caches. Build/test it without sibling checkouts, and
  exercise the expanded public API from a separate consumer using that source.
  Record archive/binary hashes, commands and results. Do not publish artifacts.

## Implementation slices

1. [x] Audit selected source records/artifacts and create sanitized fixtures,
   a traced case manifest and expected results. Include unsupported workflows
   and semantic probes. Document sampling, sanitization and reconstruction.
2. [x] Add a reusable Zig qualification runner/build step using the existing
   test-support package. Preflight behavior/exit statuses, compute coverage,
   measure equivalent cases and persist raw/summary evidence. Validate comparison
   and measurement parsing with focused checks. Steps 1 and 2 form one verified
   feature slice (0.12.0), because fixtures and runner qualify each other.
3. [x] Extend the separate package consumer for bindings, named feeds, slurp,
   predicates, decimal statistics and predicate status. Verify fresh source
   packaging and consumer execution with isolated caches in native Debug. Commit
   the verified consumer/test slice independently; bump a patch version only if
   qualification finds a production defect that requires a fix.
4. [ ] Write the qualification report with measured coverage, semantic differences,
   timing/memory limits, packaging evidence and ranked next work. Mark the plan
   complete only after all required runs pass and retain reproducible evidence.

Before feature/fix commits, check/set versions through `zig build version` and
`zig build version -- set X.Y.Z`, preserving major 0 and all configured markers.
Run formatting, `zig build test` and `zig build` in native Debug for changed code;
then commit each verified slice using a temporary message file and `git commit
-F`. Remove temporary files with plain `rm`. Documentation/evidence-only commits
do not change the package version. No routine build-mode/architecture matrix.

## Acceptance and evidence

- The new qualification command runs entirely from sanitized repository data;
  the two private session stores are not required for reproduction.
- Every catalog row has a source/reason and checked reference behavior. Supported
  translations match their frozen expectations. Unexpected differences fail.
- The report includes sampled coverage, raw measurements and uncertainty, with
  semantic probes and unsupported cases separated from equivalent timings.
- A newly packaged source tree and an independent consumer pass with empty
  caches. Updated consumer tests cover public APIs added since the old example.
- All tools needed are either already installed or explicitly reported missing;
  no new interpreter-based helper is introduced.

Slices 1–2, 0.12.0: 30 observed cases, 2 isolated components, 7 contract probes
and 2 generated scale cases are traced to the two sessions. All frozen checks
passed: 25 observed translations (one null-input adaptation), five explicit
unsupported jobs, and seven expected semantic differences. Five repetitions
produced 280 samples over 28 equivalent cases, with RSS available throughout.
The runner pins/checks binaries, source and fixture hashes. Native Debug suite
checks passed (147 total: 107 language/library, 33 CLI, 4 version workflow and
3 qualification-runner checks); build and formatting passed. Data/provenance and
performance limitations are in the corpus/report documents.

Slice 3: four public-API consumer tests pass in the checkout and in a separate
temporary project depending only on the extracted archive. A fresh source tree
with empty local/global caches and an initially absent local `zig-pkg` passes
147/147 tests, builds jqz 0.12.0 and replays all 41 corpus cases (56 smoke
measurement samples). Source/corpus fingerprints match the measured checkout.
The consumer uses a different empty cache pair and local package directory.
All three bundled dependency checksums pass. Rebuilding the source archive
unchanged reproduces SHA-256
`0412226d66bb709c641fc3e019b9b843eb005a0759785dcc882d2831766e0a08`.
Zig 0.17.0 uses `ZIG_GLOBAL_CACHE_DIR` for the global cache; its package-cache
override must stay relative (`ZIG_LOCAL_PKG_DIR=zig-pkg`). Formatting passed.
No production defect or runtime-version change was needed for this test slice.
