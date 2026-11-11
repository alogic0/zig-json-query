# Null-input CLI execution

Status: complete. Implemented and qualified as jqz 0.28.0 in native x86_64 Linux
Debug.

## Objective and contract

Add `-n` / `--null-input` for argument-only JSON construction. The existing
`argument-record` workflow currently supplies a null fixture. Remove that
invocation workaround while preserving its query, frozen jq oracle, expected
output and observed-case identity. No query syntax or public library API changes
are needed; reuse anonymous `Stream.feed("null")` and normal completion.

- Supply one anonymous null value when the stream requests input. Preserve
  early stopping, retaining stages, diagnostics, output flushing and `-e`.
  `input_filename()` returns null; diagnostics identify synthetic input as
  `<null>`.
- Read no input data from stdin or named files. Ignore data-file arguments,
  including repeated `-`, without opening them. Null input takes precedence
  over `--ndjson` and `--slurp`, regardless of option order; no slurp collector
  is created. Existing input behavior remains in effect without `-n`.
- Keep query/binding validation and the 64 KiB query limit. Named query files
  are still opened. With `-n -f -`, stdin supplies only query text and explicit
  data filenames are unnecessary. Ordinary `-f -` restrictions remain.
- Compose with string/JSON bindings, raw/sorted output, predicate status,
  `--`, aggregates and queries that request no input. An omitted/invalid query,
  invalid binding or query-file failure remains an error.
- Update `argument-record` to use `-n` and no input files. Both invocations can
  now be measured equally: remove its measurement exclusion. Keep all 45 cases
  and 30 observed translations; expect zero invocation adaptations, 35 measured
  equivalent cases and 70 one-repetition smoke samples. Historical reports stay
  unchanged; smoke measurements make no performance claim.

## Verified slices

1. [x] Record this plan, inspect CLI/session/test/qualification APIs and installed
   jq behavior, and link it from the README. Commit the plan before code changes.
2. [x] Implement the CLI branch and focused acceptance coverage. Prove that the
   command finishes while stdin remains open, skips malformed/missing data files,
   handles named/stdin query files and preserves completion/status/error behavior.
   Update help, examples, README/DESIGN and the current corpus notes/case. Read
   `zig build version`, use the pinned tool to set minor version 0.28.0 with major
   0 unchanged, and include all updated markers. Validate native x86_64 Linux
   Debug with `zig build`, CLI tests and the full suite; commit this slice.
3. [x] Run the frozen corpus once with the committed feature and preserve the
   generated evidence. Check the unchanged argument-record oracle and all case
   exits/output, zero adaptations, 70 samples and source/tool identity. Document
   current versus historical evidence and mark the plan complete in a final
   documentation commit. Existing standalone-package checkpoints remain frozen;
   no packaging rerun or other build mode is needed for this CLI change.

All new implementation/tests are Zig and reuse pinned helpers. Existing tools
are sufficient; no new tool or dependency is needed from the inventory. Commit
each verified slice using a complete temporary message file and `git commit -F`;
remove that file after success with plain `rm`. No publication or major-version
change is included.

## Verification record

Planning: the checkout is clean at 0.27.1. Installed jq 1.7 ignores input files
under `-n`, gives null even with `-s`, and reports a null input filename. The
existing jqz anonymous feed already provides null provenance. jqz's own stdin
query-file support extends naturally to `-n -f -`; it does not require a new
input reader or a change to library ownership.

Feature verification: native `zig build` and all 233 project tests pass (158
library, 42 CLI, four version-workflow, three qualification-runner, eighteen
profiler and eight distribution-verifier checks). Five new CLI tests cover
null-input behavior, including commands completing with stdin still open.
The documented artifact-record query runs successfully with typed bindings and
no data input. Version markers are synchronized at 0.28.0, formatting/diff checks
pass, and an independent comparison confirms that every case's jq invocation,
origin and frozen jqz expected result remain unchanged. The argument-only case
now uses `-n` without files and is eligible for timing; the committed replay
below validates that changed invocation.

The committed feature snapshot is
`301a0f5c7aa8f84ea272c5b7d8c40c9a7e074e35`. The
[one-repetition replay](../qualification/2026-11-11-null-input.json), generated
with `zig build qualify -- --repeat 1 --out zig-out/qualification/2026-11-11-null-input.json`,
passes all 45 cases, all 30 observed translations and ten intentional probes.
Both argument-record invocations are identical, use `-n` with no input files,
exit zero and emit the same 71-byte output hash. The case is measured with an
unchanged frozen oracle: zero invocation adaptations, 35 equivalent measured
cases and 70 samples. Source and CLI hashes match, and the preserved JSON is a
byte-identical copy of the generated report. Historical evidence is unchanged.
Report SHA-256:
`b20e5b1be472117d8576dd89db156108676e91da30977798a0d42f561378ec41`.
No additional implementation steps remain; these one-repetition observations
establish functionality without a new performance claim.
