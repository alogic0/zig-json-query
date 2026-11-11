# Automation and report comparison

Status: in progress; implementation authorized on 2026-11-10.

## Objective

Complete the remaining work identified by the practical session review: shell
gates, typed external values, multiple reports with source metadata, quantified
validation, and fractional timing statistics. This extends the completed
[report-query plan](2026-11-09-language-summaries.md), starting from 0.6.0.
New implementation/helper code uses Zig and existing dependencies. Qualification
uses native x86_64 Linux Debug only.

## Contracts and implementation steps

### 1. Predicate exit status (0.7.0)

- [x] Track the last successfully emitted JSON value in the execution session,
  independently of raw serialization, without retaining the value itself.
- [x] Expose `Stream.predicateStatus()`: 0 for any last value except false/null,
  1 for false/null, 4 for no emitted value. Zero, empty strings/containers are
  values and produce 0. This output classification does not change strict
  boolean expression/predicate semantics.
- [x] Add `-e` / `--exit-status` to the CLI. Apply the status after successful
  completion and output flush. Query/input/evaluation/IO errors retain status 2
  and take precedence. Default successful status remains 0, including no output.
- [x] Cover last-value ordering, raw strings, empty/no-output streams, completion
  aggregates, early stop, open stdin, error precedence and failed output writes.

### 2. Typed external arguments (0.8.0)

- [x] Add `--arg NAME VALUE` (a UTF-8 string) and `--argjson NAME JSON` (one strict JSON
  value with exact number tokens). Bind `$NAME` as a scalar expression, including
  field/index access and use inside array-function bodies. Bodies do not shadow
  external variables. Names use `[A-Za-z_][A-Za-z0-9_]*` and are case-sensitive.
- [x] Reject duplicate/invalid names and unbound variables. Validate all bindings
  before reading input, including unused JSON values. Limit to 128 bindings,
  64 MiB of total value text and 128 JSON container levels; reject duplicate JSON
  keys. No shell interpolation or evaluation of argument contents.
- [x] Add `Program.compileWithBindings` and a public binding description while
  preserving `Program.compile`. Own the bound text/values for the program's
  lifetime; a referenced binding compiles as a constant expression.
- [x] Test exact numbers, nested values, literal quoting/newlines, null/false,
  unknown/malformed variables, typed errors, program ownership, independent
  sessions, query files, argument terminators and allocation failure cleanup.

### 3. Multiple files, metadata and slurp (0.9.0)

- [x] Accept zero or more input filenames after QUERY, or after `-f QUERY_FILE`.
  Default to stdin; `-` explicitly selects stdin. Allow at most one stdin input.
  `-f -` requires explicit named inputs and cannot share stdin with input data.
  Filenames after `--` are literal. Remove the old one-input positional limit.
- [x] Feed all documents (or all nonblank NDJSON lines) into one ordered session;
  aggregates span files. Reset line numbers per file. Open files only when input
  is requested, so satisfied `take` skips later files and their errors.
- [x] Add zero-argument `input_filename()` returning the current input label
  (`<stdin>` for CLI stdin). Return null when no single source exists: anonymous
  library input, completion aggregates and slurped input. Add named library feeds;
  metadata is borrowed only during a feed and copied by retaining stages.
- [x] Add `-s` / `--slurp`: collect all source values into one array and evaluate
  the query once after input completion. Empty NDJSON yields `[]`. Keep the
  one-document-per-file and per-line limits; reject an invalid/later source
  before running the slurped query. Charge owned values and array capacity to a
  separate 64 MiB input-collection budget; nesting includes the wrapper array.
- [x] Share input validation between normal feeds and the owned slurp collector.
  Preserve exact numbers, duplicate/depth rejection, stream failure behavior and
  input labels. Slurp collector storage lives through downstream evaluation.
- [x] Test files/stdin/query-file combinations, local diagnostics, aggregate and
  early-stop scope, empty streams, metadata lifetime, slurp limits, source errors
  and allocation failures. Add runnable batch-provenance examples.

### 4. Quantified predicates (0.10.0)

- [x] Add `all(array, predicate)` and `any(array, predicate)` with the item binding
  and source paths of `filter`. Evaluate the array once and predicates in order.
  Require booleans for evaluated predicates. Empty all is true; empty any false.
- [x] Short-circuit on the first false (all) or true (any). Skipped predicates
  are not evaluated. Return one boolean without materializing another array.
  Restore surrounding scopes on success/failure, including nested quantifiers.
- [x] Test empty/nested/short-circuit/type/missing cases, diagnostics, external
  bindings, batch-report validation with `-e`, and parser/evaluator fuzz seeds.

### 5. Fractional timing statistics (0.11.0)

- [ ] Add `mean(array, PLACES)` and `divide(lhs, rhs, PLACES)`. Precision is a
  required constant integer from 0 through 18. Mean accepts an array of numbers;
  empty mean returns null. Division by zero and nonnumeric/missing operands error.
- [ ] Define bounded exact decimals: normalize JSON decimal/exponent spellings
  to a signed i128 coefficient and a scale from 0 through 18; trim insignificant
  trailing zeros before range checks. Out-of-range values error explicitly.
  Preserve existing arbitrary-token passthrough/comparison outside these calls.
- [ ] Compute with bounded wide integer intermediates (Zig i512), never floats.
  Align decimal scales, sum exactly, then round the final rational result once
  using nearest/ties-to-even. Reject a rounded scaled coefficient outside i128.
  Serialize exactly PLACES fractional digits, including trailing zeros, and
  normalize negative zero. Existing integer operators and stream `sum` stay exact.
- [ ] Track the offending array element/operand in numeric diagnostics. Cover
  both signs, halfway/near-halfway cases, repeating fractions, carries, zero,
  exponent spellings, precision/range boundaries, empty arrays, large integers,
  nested calls, independent reference checks and allocation failure cleanup.
- [ ] Add a runnable timing query converting nanoseconds to fractional
  milliseconds, e.g. `divide(mean(.sample_elapsed_ns, 6), 1000000, 6)`.

## Slice workflow and completion criteria

For each numbered slice: check `zig build version`, set the stated minor version
using `zig build version -- set X.Y.Z`, update README/DESIGN and examples where
relevant, run `zig fmt --check`, `zig build test --summary all`, and `zig build`
in native Debug. Commit that verified slice using a temporary message file and
`git commit -F`, then remove the message file with plain `rm`. No major bump,
architecture/build-mode matrix or new external-tool prerequisite is planned.

Completion requires all five slices, passing focused/whole-suite checks and
executable examples. Record executed evidence below and update the original
plan's cross-reference when finished.

## Verification record

- 0.7.0: native Debug `zig build test --summary all` passed 105 tests (80 library,
  21 CLI, 4 version workflow). Includes raw-output classification, completion and
  last-value behavior, early termination with stdin open, IO/error precedence.
  Native Debug build and formatting checks passed.
- 0.8.0: native Debug suite passed 113 tests (85 library, 24 CLI, 4 version
  workflow), including query-file/argument combinations, binding ownership,
  unused-value validation, limits and allocation-failure cleanup. Build and
  formatting checks passed. External values compile as owned constants.
- 0.9.0: native Debug suite passed 126 tests (91 library, 31 CLI, 4 version
  workflow). Includes multi-file/stdin/query-file combinations, per-file lines,
  cross-file aggregates, demand-driven file opening with open stdin, emitted
  output/error precedence, slurp admission/poisoning, metadata and value lifetimes,
  and allocation-failure cleanup. Build, formatting and the batch-provenance
  example passed. The test fixture preserves sentinel-terminated path ownership.
- 0.10.0: native Debug suite passed 133 tests (97 library, 32 CLI, 4 version
  workflow), including nested/short-circuit scopes, item paths, typed arguments,
  strict booleans and slurped multi-report gates. A scalar check uses a zero-byte
  allocator to verify that quantifiers do not allocate result arrays. Expanded
  fuzz seeds, formatting, build and the passing report-gate example succeeded.
