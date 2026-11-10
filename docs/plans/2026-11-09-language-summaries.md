# Practical report queries

Status: implemented and verified locally; implementation authorized on 2026-11-09.

## Evidence and scope

Session `01a1be00-ab98-7b72-b24c-b385d5ff701e` in `.codex` and session
`01a1c2a9-b739-7e13-b134-3167995ee5d1` in `.codex-llc` use jq to summarize
acceptance reports, inspect compiler progress, select failures, and compare
provenance. A snapshot contained 534 query sites in 479 executed shell commands:
381 used `length`, 77 used negative indexes or slices, 140 used `select`, and
25 used `group_by`. These are query sites, not loop iteration/process counts.

Implement the proposed query-language improvements in three verified slices.
Expressions keep producing one value; pipeline expansion stays explicit through
`each`. The CLI's predicate exit status, multiple-file input, and external
arguments are separate future work. Fractional statistics require a later
precision/rounding contract; exact integer arithmetic remains the current rule.

## Contracts

### Shorthand and container functions

- `{passed, result}` expands to `{passed: .passed, result: .result}`. Quoted
  names work too: `{"a-b"}` reads `.["a-b"]`. Explicit fields and shorthand can
  mix. Missing fields remain errors; use an explicit optional access/default.
  Duplicate names (including decoded quoted names) and trailing commas error.
- `length(expr)` returns an exact integer: element count for arrays, field count
  for objects, Unicode scalar-value count for strings (not bytes or graphemes).
  Null, booleans, numbers and unhandled missing values error.
- `keys(expr)` returns sorted UTF-8 string keys for an object, or exact integer
  indexes in ascending order for an array. Other types and missing values error.
  Empty containers produce `[]`. Both functions evaluate their argument once.

### Array indexes and slices

- Literal negative indexes count from the end: `[-1]` selects the last element.
  Positive indexes retain their existing range. Signed literal magnitudes must
  fit `usize`; decimal/exponent spellings and dynamic expressions error.
  `-0` is index zero. No signed-negation overflow is needed for large magnitudes.
- Out-of-range positive or negative indexes error unless followed by `?`.
  Missing bases propagate; optional access still rejects a wrong container type.
- `[start:end]` returns one array with an inclusive start and exclusive end.
  Omitted bounds mean the beginning/end. Negative bounds count from the end.
  Bounds clamp to `[0, length]`; reversed bounds produce `[]`. Support `[:]`,
  `[-3:]`, `[:10]`, `[1:4]`, and chained field/index/slice operations.
- Slices accept arrays only. A slice of a present array always exists, so a
  following `?` does not change its result. A missing base propagates.
- Index diagnostics retain the literal negative index. A slice constructs a
  value, so downstream diagnostics do not claim a unique source-array path.

### Scalar array transformations

- `map(array_expr, body_expr)` evaluates the array once in the surrounding
  context, then evaluates the body once per element with `.` bound to that
  element. Return one array, preserve order, and require one nonmissing value
  per element. Objects/nulls/numbers are valid mapped results.
- `filter(array_expr, predicate_expr)` uses the same binding and order, requires
  a boolean per element, and returns the original matching elements in one
  array. False is preserved as a mapped value and drops an element in a filter.
- Functions nest inside projections, arguments and pipeline stages. Empty
  arrays never evaluate the body/predicate. Wrong input types error even when
  empty-like; no implicit expansion, coercion or truthiness is introduced.
- During body evaluation, diagnostics track the source array's actual item
  index, including nested transformations. Computed arrays have no invented
  source path. Scope restoration applies on success and failure.
- Arrays and computed values use the current expression-stage arena. Borrowed
  input children remain valid during synchronous downstream processing; existing
  retaining stages deep-copy them. Functions materialize arrays and do not add
  incremental parsing or disk spilling. Existing depth/query/retention limits
  continue to apply; the retention budget is not a scalar-temporary/RSS bound.

## Slices and validation

1. [x] Shorthand, `length`, `keys`: parser/evaluator, semantic and error tests,
   CLI report-summary coverage, README/DESIGN, version 0.4.0.
2. [x] Negative indexes and slices: range-safe parsing/evaluation, diagnostics,
   boundary/composition tests, CLI recent-command coverage, docs, version 0.5.0.
3. [x] `map`/`filter`: scoped evaluation, diagnostics, nested/empty/error cases,
   retention lifetime and allocation-failure checks, CLI summary/NDJSON coverage,
   executable report examples, docs, version 0.6.0.

For each feature slice, check the current version with `zig build version`, set
the minor version using `zig build version -- set X.Y.Z`, run formatting checks,
`zig build test --summary all` and `zig build` in native x86_64 Linux Debug, then
commit the verified slice using a temporary commit-message file. Update this
plan with results before committing. No routine build-mode/architecture matrix.

## Acceptance queries

```text
{passed, cleanup_passed, requests: length(.http), result}
{commands: length(.), recent: .[-3:]}
.http | each | group_by(.status) | {status: .[0].status, count: length(.)} | collect
{passed, cleanup_passed, requests: length(.http),
 last_request: .http[-1]? ?? null,
 failures: filter(.fixtures, .result.code != 0)}
map(.fixtures, {case, code: .result.code})
```

## Verification record

- Slice 1, 0.4.0: `zig build test --summary all` passed 80/80 tests (60
  library/language, 16 CLI, 4 version-workflow). Includes the HTTP grouping
  acceptance query, decoded shorthand keys, Unicode scalar counts, sorted keys,
  strict type/missing errors, diagnostics, and retained NDJSON summaries.
  Native Debug build and formatting checks passed.
- Slice 2, 0.5.0: `zig build test --summary all` passed 87/87 tests (66
  library/language, 17 CLI, 4 version-workflow). Generated slice checks cover 448
  combinations against an independent position-selection model. Boundary tests
  cover empty arrays, full `usize` magnitudes, `-0`, omitted/clamped/reversed
  bounds, malformed/dynamic bounds, optional/type behavior, source paths, chained
  access, compiler summaries, and retained borrowed views across input reuse.
  Native Debug build and formatting checks passed.
- Slice 3, 0.6.0: `zig build test --summary all` passed 100/100 tests (77
  library/language, 19 CLI, 4 version-workflow). Covers nested bindings and scope
  restoration, exact token/false/null preservation, empty bodies, strict types,
  missing results, nested source paths, output depth, delayed retention after
  input reuse, stream poisoning/budgets, and allocation failures throughout
  compile/evaluate/collect. Parser/evaluator fuzz seeds include the new syntax.
  Native Debug build, formatting checks, and both executable query-file examples
  passed. No missing tools or additional dependencies were needed.

Run the report examples:

```sh
./zig-out/bin/jqz -f examples/report-summary.query examples/acceptance-report.json
./zig-out/bin/jqz -f examples/recent-commands.query examples/compiler-commands.json
```
