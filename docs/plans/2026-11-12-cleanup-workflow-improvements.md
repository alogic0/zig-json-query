# Cleanup workflow improvements

Status: complete at 0.33.0. All four code slices, focused workflow checks and
the unchanged qualification corpus pass in native x86_64 Linux Debug. The
[completion report](../qualification/cleanup-workflows-2026-11-12.md) records
the commits, measured evidence and remaining limits.

Fix shared shell redirection, make large manifest queries easier to run within
explicit memory budgets, and support efficient comparisons by key. These needs
come from using `jqz` during the `z_llvm` artifact cleanup on 2026-11-12.

The reviewed baseline is 0.30.0, commit `002ac006b01700481af6621a305e508058e752aa`.
Work in `/home/oleg/prog/zig-json-query`. Follow `AGENTS.md`, use Zig and the
existing pinned packages, and keep each verified slice in a separate commit.

## 1. Fix shared stdout redirection

Priority: first. This is a reproduced correctness bug.

```sh
{ ./zig-out/bin/jqz -n '111'; ./zig-out/bin/jqz -n '222'; } > output.txt
cat output.txt
```

Expected bytes: `111\n222\n`. Observed at 0.30.0: `222\n`. The same commands
through a pipe produce both lines. During cleanup, repeated invocations under
one redirected shell loop also overwrote earlier JSON records.

Inspect the use of `std.Io.File.stdout().writer(...)` in `src/main.zig` and the
corresponding Zig 0.17 descriptor semantics. Preserve the inherited descriptor's
current position. Do not seek back to the start or truncate inherited output.
Check stderr for the same issue.

Acceptance:

- Sequential invocations sharing one regular-file stdout descriptor preserve
  both outputs in order. Include a prewritten prefix and differing output lengths
  so overwriting and stale trailing bytes are caught.
- Pipes and append redirection still work. Verify JSON, raw and joined output,
  help/version output, and diagnostics through inherited descriptors.
- Flush behavior and exit-status/error precedence remain correct, including
  failed writes. Add native CLI regression coverage using the existing helpers;
  exercise the shell reproduction as an independent check.

## 2. Improve memory controls and grouped totals

Priority: second. A large manifest can pass normal input admission but fail
under `-s` because owned parsed values exceed the separate slurp budget.
The bare `SlurpTooLarge` diagnostic does not explain that distinction.

One observed input is 29,723,599 bytes:

```text
/home/oleg/prog/z_llvm/local-state/retirements/historical-artifacts-audit-20261112/audit.json
```

This is optional, read-only qualification data. Do not modify it, commit it,
or require it for tests. Use generated fixtures for portable regression checks.

Expose separate CLI controls for retained collection bytes and slurp bytes.
Suggested names are `--max-retained-bytes` and `--max-slurp-bytes`. Keep the
current 64 MiB defaults. Validate values and overflow explicitly; do not add an
implicit unlimited mode or confuse these budgets with input text size or RSS.
Reuse the library's existing configurable retention/slurp mechanisms where
possible. Document which allocations each budget covers and which it does not.

Budget failures should identify the operation or budget, its configured limit,
and the relevant requested/retained allocation when available. Give a useful
remedy, such as a budget option or avoiding unnecessary slurping. Preserve the
distinction between budget rejection and allocator exhaustion.

Also add a minimal way to calculate a count and checked integer sum per key
without retaining all records in each group. The result should retain only the
distinct keys and their accumulator state, under an explicit budget. Choose
names and syntax consistent with the current scalar/stage distinction and
record the contract here before implementing it. Preserve first-seen group
order and existing key equality/type rules. A general reducer language is not
required for this request.

Acceptance:

- Existing invocations keep their default limits and result semantics.
- Small, explicit budgets produce actionable errors. Valid overrides are
  honored independently; invalid values and overflow fail before input work.
- A synthetic manifest demonstrates normal input admission versus slurp
  retention failure, then succeeds with a sufficient explicit slurp budget.
- Grouped count/sum results match the existing materialized queries for empty
  input, repeated keys, multiple files, negative values and exact large integers.
  Integer overflow and invalid values fail without emitting partial totals.
- With a fixed set of keys and growing NDJSON input, retained allocation grows
  with the keys rather than the number or payload size of records. Measure this
  using the existing allocation helpers and distinguish it from process RSS.
- CLI/library ownership, early-stop behavior, completion and allocation-failure
  cleanup remain covered.

## 3. Add keyed lookup and manifest comparison

Priority: third. Comparing old and new manifests by file path currently requires
repeated filtering or a separate Zig program. Support building an index once
and using computed keys to look up matching records.

Start with string keys such as file paths. Preserve exact numeric values in
the records. Define duplicate-key behavior explicitly; reject duplicates by
default instead of silently losing records. Keep missing, null and false
distinct, following existing strict/optional access rules.

Provide concise examples for an inner match and a left match between two
manifests. A separate join operator is optional if index construction, computed
lookup and the existing pipeline express both operations clearly. Do not
reintroduce implicit Cartesian expansion or rescan the entire right-hand
manifest for every left-hand record. Document storage ownership and memory
limits for the index.

Acceptance:

- Compare records by `.path`, report changes to `.sha256`/`.size`, and retain
  left-input order. Demonstrate how to report added and removed paths.
- Cover empty inputs, missing matches, present null/false values, duplicate
  keys, Unicode/escaped keys and integers above the floating-point exact range.
- Index construction and lookup respect declared memory limits, safely outlive
  borrowed input buffers where required, and release allocations on failure.
- A generated workload confirms that repeated lookups use the built index;
  include a large-group case that would expose a nested linear scan.

## Delivery and validation

- [x] Commit this request before implementation starts.
- [x] Fix descriptor output, verify it, and commit a patch-version slice.
- [x] Add memory controls and diagnostics, verify them, and commit a feature slice.
- [x] Add grouped count/sum accumulation, verify it, and commit a feature slice.
- [x] Add keyed lookup/comparison, verify it, and commit a feature slice.
- [x] Update README, design notes and query examples for the implemented APIs.
- [x] Run the existing qualification corpus and focused workflow checks; record
  actual results and mark this request complete only when every required slice
  is delivered.

Use native x86_64 Linux Debug for routine builds and tests, as `AGENTS.md`
requires. Read the package version before each code slice and use the pinned
version tool for the appropriate patch/minor increment. Keep major version 0.
Write commit messages to temporary files, use `git commit -F`, and remove those
files with plain `rm` after successful commits.

Keep filesystem scanning, hashing and deletion in their existing tools.
This request changes `jqz` query/output behavior; it does not authorize any
cleanup or changes to compiler inputs, retained evidence, sibling libraries,
or other agents' work. Do not publish or push changes.

## Implementation evidence

Keyed-comparison contract (recorded before implementation): stream stage
`index_by(key)` builds one string-keyed object and emits it at completion (`{}`
for empty input). Values are owned copies of entire records, with exact numeric
tokens; duplicate decoded keys are errors. Its key/record/map capacity shares
`--max-retained-bytes`, and the object wrapper counts toward depth. Computed
object access `object[expression]` requires a string key; append `?` to allow
absence only. Missing, present null and present false remain distinct through
`exists(...)`; wrong base/key types still error. Literal array indexes/slices
keep their existing rules; computed array indexes are outside this slice.

Scalar `root()` returns the input to the current expression stage, unchanged
inside nested map/filter/all/any bodies. This supplies the outer built index
without new variable bindings: `$after[0] | each | index_by(.path) |
map($before[0],{before:.,matched:exists(root()[.path]?),after:root()[.path]? ?? null})`.
That left match preserves left order; `each | where(.matched)` selects inner
matches, `where(not .matched)` selects removed paths, and reversing before/after
selects added paths. Index construction happens once per stream, and lookup uses
the object's existing hash index rather than scanning or rebuilding records.
Scalar lookup/root values borrow until synchronous consumers finish; downstream
retaining stages own copies under the same budget. The index is released after
completion or failure. No implicit expansion or general reducer is introduced.

Grouped-total contract (recorded before implementation): stream-only
`count_by(key)` emits `{key,count}`; `sum_by(key,value)` emits
`{key,count,sum}` with the number of contributing records and a checked i128
sum. Key/value expressions run once per accepted record in that record's scope.
Empty input emits no groups; append `collect` for `[]`. Preserve first-seen
group order and the first key's representation, using the same structural
equality/type/numeric rules as `group_by`. Own only distinct keys and fixed-size
accumulators; charge arena/row capacity and completion object scratch to the
shared retained budget. Transient key/value evaluation stays scalar storage.
The output object's wrapper counts toward depth admission. Validate/accumulate
before completion so invalid values and integer overflow emit no partial totals.
Search distinct keys linearly (O(records × distinct keys)); retained capacity is
O(distinct keys and their size), independent of other record payloads. Normal
take/completion, synchronous borrowing and downstream-copy rules apply.

Memory-control contract: `--max-retained-bytes N` maps to the existing session
`max_collect_bytes`; `--max-slurp-bytes N` maps to the independent `Slurp`
allocator. Both default to 67,108,864 bytes. Accept only unsigned decimal bytes
representable by `usize`, including zero as a zero-allocation budget; there is
no unlimited sentinel or unit suffix. Reject invalid arguments before reading
query/data files. Diagnostics retain the budget kind, limit, live capacity at
rejection and attempted allocation size even after cleanup, and give the
applicable CLI remedy. Allocator exhaustion remains `OutOfMemory`.

0.30.1 uses streaming writers for both inherited stdout and stderr. Zig 0.17's
default positional writer starts at byte zero; the streaming writer preserves
the shared descriptor offset. Native build and all 251 project checks pass,
including two new descriptor tests. Prefixes, differing lengths, JSON/raw/joined
output, help/version, diagnostics, pipes and shell shared/append redirection
pass. Failed writes still override predicate/informational exits. The original
two-command shell reproduction independently produces `111\n222\n`.

0.31.0 passes native build and the complete 256-check suite (162 library,
58 CLI, three binding-input, four version, three qualification, eighteen
profiler and eight distribution checks). Five new checks cover invalid/overflow
arguments before IO, zero/independent budgets, generated-manifest admission,
structured diagnostics after cleanup and allocator-exhaustion distinction.
The optional 29,723,599-byte audit also passes ordinary input (`length(.)` = 15),
fails default slurping with limit 67,108,864 / retained 46,981,016 / requested
29,209,288 bytes, and succeeds with `--max-slurp-bytes 268435456`
(`length(.[0])` = 15). Its SHA-256 stays
`2f9f150d6c8a4a1c93474194a7c5fe0157eaa8549c9836392ed49454c183beee`.
The private input is read only and is not required by portable tests.

0.32.0 passes native build and the complete 264-check suite (169 library,
59 CLI, three binding-input, four version, three qualification, eighteen
profiler, eight distribution), plus the focused wrapper-depth regression.
Seven library tests and one CLI test cover materialized-query equivalence,
empty/mixed/structural keys, exact/negative integers, source reuse, multiple
files, invalid/overflow values, count overflow, budget/writer failures,
take/completion and allocation-failure injection through aggregate handoffs.

`zig build study-cleanup` uses the existing allocation meter. The
[generated evidence](../qualification/2026-11-12-grouped-totals.json) records
908 live retained bytes for four keys across 32 versus 4,096 records and
16 versus 4,096-byte payloads. With 64 distinct keys, retention is 21,348 bytes.
The meter's live owner delta exactly matches the retained allocator after every
feed; all totals match independently constructed expectations and cleanup leaves
zero live bytes. These are NDJSON-style synchronous record feeds, with source
text/program/output buffer excluded and transient parsing reported separately;
the numbers are allocation capacity, not RSS. Evidence SHA-256:
`dca43d6018a334246d659de3b58fe83f3189af56b7695983284dffd637983c93`.

0.33.0 adds owned `index_by` objects, strict/optional computed string lookup and
`root()` scope. Native build and all 273 project checks pass (176 library,
61 CLI, three binding-input, four version, three qualification, eighteen
profiler, eight distribution), plus ten independent consumer checks. Seven new
library checks and two CLI checks cover empty indexes, Unicode/escaped
duplicates, null/false/missing, exact large values, source reuse, nested root
scope, depth/budgets, failed writes, allocation-failure cleanup, and all five
[manifest query examples](../../examples/cleanup/README.md).

The [0.33.0 workflow study](../qualification/2026-11-12-cleanup-workflows.json)
confirms a built hash index over 4,096 records handles 65,536 repeated left keys
(131,072 successful lookups), with zero allocation during lookup/completion and
zero live bytes after cleanup. This repeated last-key case would require a
nested scan without the index. Index retention is 2,175,024 bytes in this run.

The grouped comparison now disables in-place resize/remap using the existing
failing-allocator helper, allowing allocations to succeed. This removes
backing-allocator placement variance: in the new process layout, ordinary
growth used 908 or 1,672 bytes for four keys depending on layout/payload, while
each individual run still stayed flat after the keys were seen. Under controlled
growth all four fixed-key cases retain 1,672 bytes; 64 keys retain 33,050 bytes.
This is a measurement-method change, with the original 0.32.0 evidence retained.
All owner deltas match and cleanup is zero. New evidence SHA-256:
`a48502bf49da97b90df11e93db0ee997315a3daa7351dd9011d0f7a6b10afb19`.

The final [corpus replay](../qualification/2026-11-12-cleanup-corpus.json) uses
committed implementation `5ad37c84411da5f67f61e481e2a6c6fcb7edd564`, jqz 0.33.0
and installed jq 1.7. All 45 cases pass: 30 observed translations, three
components, ten intentional probes and two generated scale cases. There are
no unsupported observed cases or invocation adaptations. One repetition of
35 equivalent cases produces 70 samples; this is a functional checkpoint,
not a new performance claim. The case manifest and provenance are unchanged
from request commit `e7d2fbf`, and the recorded source hashes match the checkout.
Corpus evidence SHA-256:
`e56fc6d736d80617a1097fa15fd12c0a2094f46ec44d919a64eaf6fc73817348`.

Delivered slices: `18afa4c` (0.30.1 descriptor fix), `28246a6` (0.31.0 memory
controls), `f742990` (0.32.0 grouped totals), and `5ad37c8` (0.33.0 keyed
comparisons). No required implementation step remains open. Documented limits
remain: grouped key search is linear in distinct keys, computed lookup accepts
object string keys only, and retention budgets do not bound total process RSS
or scalar temporaries. The work does not add a general reducer or disk spill.
