# Design direction

jq has an unusually effective core: short field paths, filters, pipes, and JSON
construction compose into useful transformations. Its language goes much further
than searching. A filter may emit zero, one, or many results, which explains both
its expressive power and some of its learning cost.

The opportunity for a new language is to make common data inspection predictable.
Rewriting in Zig alone does not establish a usability or performance improvement.
Existing projects such as [jaq](https://github.com/01mf02/jaq) and
[gojq](https://github.com/itchyny/gojq) already explore alternative implementations.

## Changes worth making

The [jq manual](https://jqlang.org/manual/) documents stream-valued filters,
`//` defaulting past false/null, `?` as error suppression, and a `--stream` input
mode based on path/value events. These are coherent jq choices. This prototype
chooses different contracts for a different language:

| Topic | Chosen contract |
| --- | --- |
| Cardinality | Expressions return one value; stream stages explicitly expand, filter, limit or aggregate records |
| Absence | Missing, JSON null, false, and no output are distinct states |
| Optional access | Allows absence only; wrong container types remain errors |
| Defaults | `??` handles missing and null while preserving false and zero |
| Predicates | Require booleans, with explicit comparison and short circuiting |
| Numbers | Preserve input tokens and compare decimal values exactly |
| Diagnostics | Retain source positions through parsing and evaluation |
| Memory | Separate query lifetime, input lifetime, and transient stage lifetime |

The tradeoff is intentional: some jq programs become longer, and this language
does not inherit jq's general generator composition. Existing jq scripts require
translation. New features should preserve these contracts instead of silently
reintroducing multi-valued scalar expressions.

## Current implementation

Query source passes through a lexer and precedence parser into an AST. Pipeline
stages are interpreted directly. Literal regexes compile once through the shared
regex module. JSON input is parsed with `parse_numbers = false`, retaining number
tokens instead of rounding them through floating point.

Object field shorthand expands to strict current-value accesses in the AST.
`length(expr)` and `keys(expr)` are scalar functions, so counts and schema
information can appear inside report summaries without introducing generators
or nested pipelines. Length counts array elements, object fields, or Unicode
scalar values in strings. Keys produces one array of sorted UTF-8 object names
or ascending numeric array indexes. Unsupported types and unhandled missing
values keep located errors. Results use the expression-stage lifetime.

Array indexes and slice bounds use a sign plus a `usize` magnitude, preserving
the existing positive-index range and avoiding signed negation overflow.
Negative indexes resolve from the end; slices clamp bounds and return borrowed
array views with an exclusive end. Missing indexes retain strict/optional
semantics. Slice output has no unique source-array path; diagnostics for literal
indexes retain their sign. Retaining stages clone borrowed slice children.

Execution uses a persistent session spanning all input records. A projection
produces one value, a filter passes or drops it, and `each` invokes downstream
stages once per array element. `count` maintains a checked u64 counter; `collect`
deep-copies values into session-owned storage. Completion visits aggregate stages
in pipeline order, forwarding their outputs before completing later aggregates.
Thus aggregates compose across NDJSON records and handle empty streams.

`sum` and scalar arithmetic operate on checked signed 128-bit integers. Decimal
tokens are converted by digit/exponent normalization only if their mathematical
value is an in-range integer. Division is exact, fractions and overflow are
errors, and remainder follows the dividend's sign. Number preservation and
unbounded-token decimal comparison keep their separate contracts.

`sort` / `sort_by` retain owned records and keys, then use an in-place stable
sort. Keys must be uniformly numeric or uniformly strings. Numeric keys are
validated before retention, keeping the sort comparator infallible. Results
are individual records. `group_by` uses structural equality, preserves first-seen
group order and input order within groups, and emits one array per group. The
initial grouping scan is quadratic; sorting/grouping empty streams emit nothing.

When `take(n)` is satisfied, every stage up to that point stops accepting work.
The last accepted value still travels downstream, and later aggregates finish.
`take(0)` needs no source input. A scalar error after the last accepted value is
still an error; a later upstream error is skipped. IO buffering may read ahead,
but the CLI does not request another record after upstream closes. Single-document
parsing still requires the complete document unless no input is requested.

Each expression/filter stage has a temporary arena that stays alive until its
downstream consumers finish. Collectors use separate arenas and copy all retained
containers, keys, strings and number tokens. A shared budget accounts for live
retained allocation capacity, including temporary duplicate storage while one
retaining stage forwards to another. Sorting/grouping keys and grouping scratch
also use this allocator. The default limit is 64 MiB, configurable through
the library. It is not a bound on total process RSS. Failure discards collectors;
finish emits each aggregate once. Query text and regex programs have their own
owner; regex match temporaries are freed by the shared library.

Depth checks count arrays/objects consistently, including empty containers.
Input scanner diagnostics provide byte line/column positions and bounded source
excerpts. Evaluation tracks a bounded owned JSONPath through field/index access
and array expansion. It deliberately clears source provenance for constructed
values and buffered outputs instead of inventing input paths. The CLI accepts
raw string output and one query file, with explicit positional/stdin precedence.

Dependencies are source archives pinned by content hashes and shipped with the
project. Existing provider APIs remain unchanged. Separate consumer, cold-cache
distribution tests, bounded parser/evaluator fuzz targets and generated semantic
models check the implementation. A Zig harness reuses process/test helpers for
comparisons with pinned jq/jaq binaries, output equivalence, elapsed time and
child peak RSS. Local source archives exclude caches and normalize tar metadata.

This is an AST interpreter, not a compiler to LLVM. It establishes semantics
before selecting optimizations. Zig fits the ownership and allocation boundaries
and can produce a native CLI without a language runtime or GC. Memory safety still
depends on correct ownership and bounds; it does not come automatically from Zig.

## Next useful increments

The [stream execution plan](docs/plans/2026-11-09-stream-runtime.md) and
[follow-up plan](docs/plans/2026-11-09-followups.md) record implemented milestones.
The [practical report-query plan](docs/plans/2026-11-09-language-summaries.md)
tracks shorthand, container functions, relative indexes/slices and scalar array
transformations motivated by real acceptance/compiler sessions.
The [qualification report](docs/validation-2026-11-09.md) records runtime tests,
fuzz coverage and benchmark evidence. Routine validation uses native x86_64
Linux Debug. Earlier GNU/musl and other-mode results remain historical evidence.
Additional architectures will be planned only for a concrete deployment
requirement. Public publication is separate from this local
release preparation.

Real log/API/config queries should guide feature selection. Incremental parsing
within large documents remains a future engine milestone; classify supported
operations and explicit buffering/fallbacks before adding it. Optimize measured
bottlenecks before considering bytecode, stage fusion, selective parsing or SIMD.

Full jq compatibility and an LLVM/JIT backend are outside the initial scope.
