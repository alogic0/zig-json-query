# Serialization, configuration edits, structural sets and profiling

Status: implementation in progress; authorized on 2026-11-10.

## Objective

Complete the remaining priorities in the [qualification report](../qualification/README.md),
following the completed [scalar-aggregate plan](2026-11-10-scalar-aggregates.md).
Implement the three remaining observed workflow translations and measure Debug
startup, parsing and allocation costs before proposing engine optimizations.
All implementation and helpers use Zig. Validate native x86_64 Linux Debug only.

## Language and output contracts

- `tojson(value)` returns compact JSON text as a string, without an output
  newline. Preserve number tokens, object insertion order and UTF-8 text; escape
  quotes, backslashes and control characters using the existing JSON writer.
  Enforce the existing 128-container serialization limit before encoding.
- `byte_length(string)` counts UTF-8 bytes. Existing `length(string)` continues
  to count Unicode scalar values. Missing arguments/values and wrong types are
  errors. Test Unicode and escaping explicitly; the observed ASCII fixture alone
  cannot establish byte/character equivalence.
- `update(value, path, body)` replaces an existing value at a literal field/index
  path, evaluating the body with that selected value as `.`. `del(value, path)`
  removes a field or array item at such a path. Paths start at `.` and contain
  at least one field/index, including quoted fields and negative indexes; no
  optional access, slices, generators or computed selectors. Missing paths and
  wrong containers fail. Only ancestor containers are copied, preserving all
  other fields, member order and number tokens. No original input is mutated.
  Filtering the selected array in `update(., .groups, filter(...))` expresses
  the observed predicate deletion while retaining arbitrary outer fields.
- CLI `-S` / `--sort-keys` and `StreamOptions.sort_keys` recursively sort object
  names by UTF-8 bytes for output. Preserve array order, number spelling and raw
  string output. This is deterministic key ordering, not numeric canonicalization
  or a promise of jq's pretty-print whitespace.
- `sort_values(array)` and `unique(array)` use a total structural JSON order:
  null, booleans, numbers, strings, arrays, objects. Arrays compare lexicographically;
  objects compare sorted key sequences, then corresponding values. Numeric
  comparison stays exact, with the existing exponent/depth bounds. Sorting is
  stable; uniqueness retains the first original representative of equal values
  in sorted order. Existing stream `sort` and `sort_by` retain their uniformly
  numeric/string key requirement. Empty arrays return `[]`.
- New scalar allocations have the existing temporary-arena lifetime. Retained
  results are cloned into the shared retention budget; no new RSS guarantee or
  spill-to-disk behavior is introduced.

## Verified commit slices

1. [x] Commit this plan, including the afterwards work, before implementation.
2. [x] Add serialization and byte sizing, with Unicode/escape/exact-number,
   depth, diagnostics, retention and allocation-failure checks. Add a consumer
   check and translate `serialized-sample-size`, keeping its jq oracle unchanged.
   Validate build/tests and a corpus smoke run; increment the minor version via
   `zig build version -- set` and commit the verified feature.
3. [x] Implement path updates/deletion and recursive sorted-key output. Cover
   preservation of unknown fields, immutable siblings, nested scopes and paths,
   negative indexes, strict failures, raw/NDJSON/exit-status output and allocation
   cleanup. Qualify `normalize-config`, including exact compact sorted bytes in
   a separate output check. Validate and commit with the next minor version.
4. [x] Add structural sorting and uniqueness with shared ordered-object support.
   Cover mixed types, lexicographic arrays/objects, numeric spellings, stable
   representatives, independent generated models and allocation failures. Qualify
   `distinct-schema-shapes`; validate and commit with the next minor version.
5. [ ] Add a Zig profiling build step using sanitized small/large corpus inputs.
   Separate compilation, strict parsing, session setup, evaluation/emission and
   cleanup timings and allocator requests/peak live bytes. Check outputs against
   the ordinary public execution path. Measure supervised tiny CLI invocations
   to bound launch/capture costs; label this overhead explicitly. Record warm-up,
   repetitions, source/input/tool hashes, environment and limitations. Add focused
   counter/output checks; validate and commit the tooling feature with a minor
   increment. Do not infer optimizations or general performance claims from a
   Debug-only profile.
6. [ ] Run final native Debug build/tests and separate-consumer checks, then the
   full workflow qualification at five repetitions. Persist new raw evidence and
   a profiling report, preserve the 0.12.0/0.14.0 checkpoints, update remaining
   priorities from measured findings, mark this plan complete and commit the
   report slice. A feature slice's checks need repeating only after later code
   changes or unresolved failures.

Every code slice is committed before the next starts. Read the current version
with `zig build version` before each feature increment, preserve major 0, and
include all tool-updated markers. Write complete commit messages to temporary
files and use `git commit -F`; remove temporary files with plain `rm`.

## Acceptance and evidence

Observed selected-case coverage rises from 27/30 to 30/30 with unchanged frozen
jq expectations for the three former gaps. Equivalence remains scoped to these
fixtures; strict missing fields, exact numbers, empty sum and first-seen grouping
contracts remain intact. Unicode sizes and deterministic output have dedicated
checks beyond that sample. Profiles distinguish in-process phases from process
launch/capture and document allocator/RSS and cache limitations. Any unavailable
tool is reported against `/home/oleg/zig-inventory-2026-11-03`; do not add a new
interpreter or deployment target.

## Validation record

Slice 2, 0.15.0: native Debug build, 170 project tests (129 language/library,
34 CLI, four version-workflow, three qualification-runner) and six consumer tests
passed. Six serialization tests cover exact tokens, Unicode/escaping, byte versus
scalar counts, depth/paths and exhaustive allocation failures with retained
output. All 43 corpus cases passed in a one-repetition smoke run: 28/30 observed
translations, two unsupported, nine intentional probes and 62 samples. The new
Unicode probe keeps the ASCII sizing case's unchanged oracle honest. Formatting
and diff checks passed; no additional tool was needed.

Slice 3, 0.16.0: native Debug build, 181 project tests (138 language/library,
36 CLI, four version-workflow, three qualification-runner) and seven consumer
tests passed. Nine edit tests cover immutable siblings, unknown fields, nested
replacement scopes, signed indexes, strict paths, ordered/raw output, independent
filter models, retained lifetimes and exhaustive allocation failures. All 45
corpus cases passed: 29/30 observed translations, one unsupported, ten probes
and 66 smoke samples. The normalization oracle is unchanged; an additional
component checks exact compact sorted bytes and a probe records strict deletion
of missing fields. Formatting and diff checks passed.

Slice 4, 0.17.0: native Debug build, 189 project tests (145 language/library,
37 CLI, four version-workflow, three qualification-runner) and eight consumer
tests passed. Seven new structural tests cover full type/array/object order,
normalized equality with original representatives, schema composition, strict
source failures, comparison depth, 300 generated finite-universe models and
exhaustive allocation failures with retained input lifetimes. All 45 corpus
cases passed: 30/30 observed translations, zero unsupported, ten probes and 68
smoke samples. The distinct-schema oracle and its array order are unchanged.
Formatting and diff checks passed.
