# Stream execution milestone

Status: complete, verified 2026-11-09.

Scope confirmed with the user: implement the stream milestone now; keep CLI
usability, arithmetic, sorting/grouping and release work queued below.

## Contract

One execution session operates on the entire input stream. In document mode the
source contains one JSON value; `each` expands arrays within it. In NDJSON mode
all nonblank lines feed the same session. Expressions remain single-valued.

| Stage | Input handling | End-of-stream output |
| --- | --- | --- |
| `count` | Count arriving values with a checked unsigned 64-bit counter | One exact JSON integer; `0` on empty input |
| `collect` | Deep-copy arriving values into session-owned storage | One array in input order; `[]` on empty input |
| `take(n)` | Forward at most `n` arriving values; stop upstream when satisfied | No additional output |

`take` accepts a constant nonnegative integer fitting u64. It counts values at
its position in the pipeline, not source lines. A satisfied `take` closes its
upstream stages; downstream aggregates still finish. `take(0)` consumes no input.
For example, `take(2) | count` emits `2` after two records, `count | take(1)`
requires source EOF, and `take(0) | collect` emits `[]` immediately.

Aggregates compose in pipeline order: `collect | each | count` counts collected
items, and `count | collect` emits an array containing one count. Empty upstream
streams are finalized too. A failed input/evaluation/output operation poisons
the session: buffered aggregates are discarded, never emitted as a partial
success. Previously emitted output remains written. Finish is idempotent;
feeding a finished or failed session is an error.

`collect` has a shared 64 MiB limit on live retained allocator requests across
all collectors in a session, including arena/container capacity. Library callers
can override the limit. This is not a whole-process RSS limit: parsed input,
scalar-stage temporaries, output buffering and allocator metadata are separate.
Exceeding the limit is a located evaluation error. System allocation failure
remains `OutOfMemory`. Collected data must survive release/reuse of input and
projection storage. Data may temporarily exist in two collectors during a
handoff, and both copies count toward the shared limit.

Early termination stops requesting/evaluating subsequent records. Buffered IO
may already have read ahead. Skipped records are not validated. Document mode
still parses a complete document before evaluation unless no input is needed;
incremental parsing within a document is outside this milestone.

## Implementation steps

- [x] Extend the parser with `count`, `collect`, and `take(n)` stage syntax.
- [x] Separate scalar evaluation from persistent execution state.
- [x] Add session start/feed/finish/deinit, ordered aggregate finalization,
      upstream stopping, checked counters and owned collection buffers.
- [x] Preserve `Program.run` as a one-document convenience wrapper.
- [x] Use one CLI session across NDJSON lines, stop reading when requested,
      and finish downstream aggregates on EOF or early termination.
- [x] Test empty streams, multi-record scope, mixed aggregate pipelines,
      reusable input buffers, zero/positive limits, invalid arguments, failures,
      collection budgets and injected allocation failures.
- [x] Prove CLI early termination with a producer whose input pipe stays open.
- [x] Run Debug and ReleaseSafe tests, compile the executable, check formatting,
      execute examples, and update the user/library documentation with evidence.

## Queued milestones

Update: all four milestones below were authorized for implementation in the
follow-up request. Their contracts, completion and validation are tracked in
[the follow-up plan](2026-11-09-followups.md) and
[qualification report](../validation-2026-11-09.md). The evidence below remains
the original stream-milestone checkpoint.

1. Everyday CLI: `-r` raw string output, `-f` query files, detailed JSON syntax
   locations and input-path diagnostics. Specify non-string `-r` behavior and
   argument precedence before implementation.
2. Arithmetic and aggregation: exact integer operations and `sum`, with explicit
   overflow, decimal, division and rounding contracts. Number preservation and
   exact comparison are already implemented; arithmetic is not.
3. Sorting and grouping: stream scope, stable ordering, key equality, empty
   input, memory budgets and a deliberate spill-to-disk policy.
4. Release preparation: immutable dependency packages; parser/evaluator fuzzing;
   equivalent-query benchmarks against pinned jq and jaq versions for startup,
   projection, filtering, regex, numeric precision, NDJSON and large documents.
   Record elapsed time, peak RSS, platform and semantic differences. Release
   qualification targets x86_64 Linux; additional architectures wait for a
   concrete deployment requirement.

## Validation evidence

Verified with the installed Zig 0.17.0 compiler on Linux x86_64:

| Check | Result |
| --- | --- |
| `zig build test --summary all` | 46/46 tests passed: 35 language/library, 11 CLI |
| `zig build test -Doptimize=ReleaseSafe --summary all` | 46/46 tests passed |
| `zig build -Doptimize=ReleaseSafe` | Executable built and installed |
| `zig fmt --check build.zig build.zig.zon src tests` | Passed |
| NDJSON error-log query with `count` | One result, `2`, across the whole file |
| Adult-user projection with `take(1) | collect` | One-element array preserving ID `9007199254740993` |

The CLI tests retain an open stdin pipe while waiting for `take(2) | collect`,
`take(0) | count`, and `collect | take(0) | collect` to exit. They complete without
producer EOF. Library tests cover empty input, aggregate chains, early-stop
positions, mutable input buffers, independent sessions, idempotent finish,
poisoned sessions, writer errors, shared-budget handoff and allocation failures
at every allocation in a multi-record collection scenario.

Implementation is in `src/execution.zig` and `src/collection_budget.zig`, with
scalar evaluation in `src/evaluator.zig`, the public session API in `src/root.zig`,
stage syntax in `src/parser.zig`, and source-loop handling in `src/main.zig`.
Regressions are in `src/stream_tests.zig` and `tests/cli.zig`. README and DESIGN
describe the final behavior. The queued milestones above are not implemented by
this change. Other targets and performance comparisons remain unmeasured.
