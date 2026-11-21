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

External bindings are validated and copied during `compileWithBindings`.
`$name` compiles to a literal node holding owned data in the program arena;
query/input text is never constructed from its contents. Bindings have exact JSON
number tokens and support the same scalar accesses as other values. Unknown
variables are located query errors; invalid names/duplicates/JSON are argument
errors before any input is read. Body scopes do not shadow program constants,
and bound/computed values have no invented input source path.

`root()` borrows the current expression stage's input. The evaluator captures
its value and owned path at the outermost scalar call, preserves them through
array-body scope changes, and clears the borrowed value when evaluation returns.
Each new stage/feed gets its own root. Computed object access evaluates the base
once and its string key once in the caller's item scope, then uses ObjectMap.get.
Optional access permits absence only; null/false remain present values, and
wrong base/key types error. Literal array indexes/slices keep their parser path.
Computed edit paths remain rejected. Missing-key errors append the actual key
to a known base path; constructed values have no invented source provenance.

A failed scalar assertion returns `error.AssertionFailed`. Its caller-owned
`Diagnostic` records the query offset, the current item path when known, and
an `assertion` whose `detail()` returns compact JSON bytes or null for
truncation. A fixed writer caps retained detail at 4,096 encoded bytes while
serializing. Evaluation and allocation errors propagate before capture. The
bytes survive release of the feed, stream and program, including the internal
stream used by `Program.run`. Further calls on a failed stream return
`StreamFailed` and preserve the original diagnostic until the caller reuses
it. The CLI flushes prior stdout and writes the envelope directly to stderr.

Array indexes and slice bounds use a sign plus a `usize` magnitude, preserving
the existing positive-index range and avoiding signed negation overflow.
Negative indexes resolve from the end; slices clamp bounds and return borrowed
array views with an exclusive end. Missing indexes retain strict/optional
semantics. Slice output has no unique source-array path; diagnostics for literal
indexes retain their sign. Retaining stages clone borrowed slice children.

`map(array, body)` and `filter(array, predicate)` are scalar array functions.
The array is evaluated once in the caller's context, then the body is evaluated
with each item as the current value. Each nested call restores its caller's
context, preserves order, and returns one array. Mapping requires a nonmissing
value; filtering requires a boolean and retains original matching items. Empty
arrays do not evaluate their bodies. Source paths follow actual item indexes
during body evaluation; computed arrays have no invented input provenance.
Result array slots and body temporaries use the expression-stage arena. Borrowed
children stay valid until synchronous downstream consumers finish, and retaining
stages clone them. These functions materialize arrays; their temporary allocation
is separate from the retention budget and the input-size limit.

`all(array, predicate)` and `any(array, predicate)` reuse the same item scopes
and diagnostics, return a single boolean without allocating a result array, and
stop at the first decisive result. Their empty identities are true/false,
respectively. Only evaluated predicates must be boolean; short-circuited bodies
are skipped while complete JSON input still follows the usual validation rule.

Execution uses a persistent session spanning all input records. A projection
produces one value, a filter passes or drops it, and `each` invokes downstream
stages once per array element. `count` maintains a checked u64 counter; `collect`
deep-copies values into session-owned storage. Completion visits aggregate stages
in pipeline order, forwarding their outputs before completing later aggregates.
Thus aggregates compose across NDJSON records and handle empty streams.

Sessions record only the classification of the last fully emitted value, not
its storage. `Stream.predicateStatus()` maps false/null to 1, absence of output
to 4 and all other values to 0. CLI `-e` applies this after successful completion
and flushing, while all execution/IO errors retain status 2. Raw output does not
affect classification or strict boolean expression semantics.

`concat(array)` evaluates its operand once. It validates string elements and
sums their UTF-8 byte lengths against a 64 MiB per-result limit before allocating
the result in the scalar arena. It then copies the bytes in order. The diagnostic
for a non-string includes the element index even for computed arrays whose
elements have no unique input path. Retaining a result uses the normal
downstream copy and budget rules.

`tojson` (both unary `tojson(expr)` and bare `tojson`) uses the ordinary compact
JSON writer with the same container-depth bound as output. It allocates encoded
text in the scalar arena, preserving numeric tokens and insertion order.
`fromjson` and `try_fromjson` (both unary and bare forms) reuse `input.zig`'s
`Scanner`/`ValueBuilder` parser into the scalar arena, enforcing the 64 MiB byte
cap, 128-level container limit, duplicate-key rejection and exact number tokens;
`try_fromjson` maps missing optional operands, JSON `null` and invalid JSON text
to `null` while keeping wrong non-string types and resource-limit violations as
errors. `byte_length` counts UTF-8 bytes separately from `length`'s Unicode
scalar count; neither includes a CLI output newline.

`update` and `del` compile literal paths into field/index steps. Only existing
targets are edited; optional/sliced/computed paths are rejected. Replacement
bodies use the selected value's scope and path. Ancestor containers are copied
into the scalar arena while untouched children are borrowed. Input is immutable.
`StreamOptions.sort_keys` (`-S`) uses `json_order.zig` to copy containers with
recursively sorted object keys before compact or 2-space pretty
(`StreamOptions.pretty` / `-p`) output, where empty `{}` and `[]` remain compact.
Raw/encoded string contents and numeric spellings are unchanged. Output copies
use a temporary arena, and the serializer enforces depth before copying.

`sum` and scalar arithmetic operate on checked signed 128-bit integers. Decimal
tokens are converted by digit/exponent normalization only if their mathematical
value is an in-range integer. Division is exact, fractions and overflow are
errors, and remainder follows the dividend's sign. Number preservation and
unbounded-token decimal comparison keep their separate contracts.

Scalar `sum(array)` uses the same checked integer addition in array order,
including intermediate-overflow checks, with `0` for an empty array. It locates
bad elements against the argument's source path when available. Parsing
distinguishes this call from the bare stream stage using the next token.

`mean` and `divide` provide explicit bounded decimal statistics with a mandatory
0..18-place precision. Normalized inputs have i128 coefficients and at most 18
fractional places. Zig i512 intermediates align scales, sum exactly and perform
rational division before nearest/ties-to-even rounding; the rounded coefficient
must fit i128. No floating point is involved. Output retains the selected number
of fractional digits and normalizes negative zero. Empty means return null.
Numeric errors identify the operand or source-array item. These functions do
not change integer operators or arbitrary-token passthrough/comparison.

`sort` / `sort_by` retain owned records and keys, then use an in-place stable
sort. Keys must be uniformly numeric or uniformly strings. Numeric keys are
validated before retention, keeping the sort comparator infallible. Results
are individual records. `group_by` uses structural equality, preserves first-seen
group order and input order within groups, and emits one array per group. The
initial grouping scan is quadratic; sorting/grouping empty streams emit nothing.

Stream `index_by(key)` evaluates a string key per record, rejects duplicates,
and deep-copies each key/record into a session-owned ObjectMap. The map maintains
one reusable hash index (small objects use the standard library's bounded inline
scan). All arena, entry and hash-table capacity shares the retained budget;
record depth includes the output object's wrapper. Completion emits one borrowed
object, including `{}` on empty input, then releases it after synchronous
downstream consumers return. Failure releases all index storage. Combining this
stage with computed lookup, root() and existing array functions provides ordered
inner/left comparisons without a new expanding scalar or a per-left-record
right-hand scan. Lookup itself allocates no storage; materialized map results
remain separate scalar temporaries, copied if subsequently retained.

Stream `count_by(key)` and `sum_by(key,value)` keep one owned key plus checked
u64 count/i128 sum per group. They emit `{key,count}` / `{key,count,sum}` at
completion in first-seen order, with no groups for empty input. Key validation
and equality reuse the existing grouping rules, including exact numeric equality
and structural objects/arrays. Distinct-key search is linear; original records
are never retained. Arena/row capacity and synchronous completion object scratch
use the shared retained allocator; scalar key/value work uses a transient arena.
The output wrapper is depth-validated before retention. Feed-time validation and
overflow abort all pending totals, while ordinary take/finish/output-failure
rules still apply. Downstream retaining stages copy borrowed keys/results.

The two-argument scalar forms `sort_by(array,key)` and `group_by(array,key)`
return one array, with `[]` for empty input. They cache each key once per item in
a scalar arena, borrow the original values, and restore the caller's item/path
scope after key evaluation. `rows.zig` shares stable sorting and group-array
construction across scalar and stream execution. Validation also shares exact
numeric, uniform sort-key and structural group-key rules. Scalar group order is
first-seen; summaries explicitly sort when ascending group keys are required.
The parser distinguishes top-level stage calls from scalar calls by arity;
scalar calls support postfix access and operators in the ordinary expression
parser. Retaining stages clone their results into the existing shared budget.

`sort_values` and `unique` use a total JSON order, separate from the homogeneous
stream sort keys. Prevalidation checks every nested number and comparison depth.
`json_order.zig` borrows already canonical trees and copies only ancestors whose
children or field order change. New maps allocate exact entry storage and rebuild
their indexes. An infallible stable row comparator compares types, scalar values,
lexicographic arrays and sorted object key sets/values. Original values are kept
separately; distinct sorted rows compact in place before output allocation, keeping
the first original representative. Scratch remains scalar-arena
storage, and downstream retention copies original values as usual.

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
`StreamOptions.max_collect_bytes` or CLI `--max-retained-bytes`. It is not a bound
on total process RSS. Failure discards collectors;
finish emits each aggregate once. Query text and regex programs have their own
owner; regex match temporaries are freed by the shared library.

Depth checks count arrays/objects consistently, including empty containers.
Input scanner diagnostics provide byte line/column positions and bounded source
excerpts. Evaluation tracks a bounded owned JSONPath through field/index access
and array expansion. It deliberately clears source provenance for constructed
values and buffered outputs instead of inventing input paths. The CLI accepts
raw string output and one query file, with explicit positional/stdin precedence.
`StreamOptions.join_output` defaults off, implies raw strings and suppresses all
result separators. Normal mode remains newline-delimited. Classification follows
the value only after a complete successful emission, including zero-byte empty
strings; write failures still poison the stream. Both inherited CLI output
descriptors use streaming writers, preserving shell-shared file offsets rather
than starting positional writes at zero. CLI `-j`/`--join-output` and
`-p`/`--pretty` use session options, no-argument `n/s/r/j/S/e/p` flags may be
bundled, and conflicting `pretty` + `join_output` is rejected before input IO.

CLI input files feed one session in order. NDJSON diagnostics restart their line
counter per file, and file opening follows upstream demand. Each named library
feed borrows a filename only during synchronous evaluation; retained metadata
is cloned like other strings. `input_filename()` is null for anonymous feeds,
completion aggregates and slurped arrays. File results are flushed before opening
the next file, preserving earlier output if a later open/read operation fails.

Null-input mode (`-n` / `--null-input`) supplies the existing anonymous feed with
the validated constant `null` once when input is requested. It bypasses data-file
opening, stdin data and slurp allocation; `--ndjson` and `--slurp` have no effect.
Named query files and bindings keep their validation, and `-n -f -` reads query
text from stdin without requiring data files. Anonymous provenance makes
`input_filename()` null, while CLI diagnostics use `<null>` as their label.
Completion, early stopping and predicate status use the ordinary stream path;
no new library API or query syntax is introduced.

Slurp uses the same validated parser as ordinary feeds, deep-copies values into
a stable-address collector and charges array/arena capacity to a separate input
budget. CLI `--max-slurp-bytes` configures it with a 64 MiB default. Container depth includes the outer
array; failure poisons the collector. The complete array is borrowed during one
`feedSlurp`, and downstream retaining stages copy their own data. Parsing,
scalar temporaries and ordinary retention still have separate lifetimes/budgets.
Budget arguments are unsigned decimal byte counts fitting `usize`; zero forbids
allocations and is never an unlimited sentinel. `Diagnostic.budget` preserves
kind/limit/live/requested sizes at rejection, including after collector cleanup.
Its writer gives the corresponding CLI remedy. Allocation failure from the
backing allocator stays `OutOfMemory`, distinct from configured budget rejection.

CLI `--slurpfile` and `--rawfile` prepare values through the existing
`Binding.json`/`Binding.string` interface. `file_bindings.zig` frames successive
JSON values with the standard Scanner and assembles one bounded array without
normalizing token spellings. Ordinary compilation then enforces duplicate keys,
UTF-8, depth, name uniqueness and typed values, including unused bindings. Named
reads stream to a finite limit rather than trusting stat size; `-` is literal.
Raw source text and prepared binding text each share the 64 MiB binding cap.
The CLI closes files promptly and releases preparation buffers after compilation
owns copies, before primary input/evaluation. This adds no library file IO API.

Dependencies use GitHub Git URLs pinned by full commits and Zig content hashes in
`build.zig.zon`. Fresh builds download the sources; subsequent builds reuse the
package cache. Existing provider APIs remain unchanged. Separate consumer and
cold-cache distribution tests, bounded parser/evaluator fuzz targets and
generated semantic models check the implementation. A Zig harness reuses
process/test helpers for comparisons with pinned jq/jaq binaries, output
equivalence, elapsed time and child peak RSS. Local source archives exclude
caches and normalize tar metadata.

This is an AST interpreter, not a compiler to LLVM. It establishes semantics
before selecting optimizations. Zig fits the ownership and allocation boundaries
and can produce a native CLI without a language runtime or GC. Memory safety still
depends on correct ownership and bounds; it does not come automatically from Zig.

## Next useful increments

The [session-derived qualification](docs/qualification/README.md) checks sanitized
workflows against frozen per-tool results and exit codes before timing equivalent
translations. Exact decimal comparison preserves precision; array/result ordering
and raw bytes remain observable. Unsupported jobs and deliberate contract probes
are distinct from successful translations. Input/source/tool hashes and raw
native Debug timing/RSS samples make the selected-case evidence reproducible.

The [stream execution plan](docs/plans/2026-11-09-stream-runtime.md) and
[follow-up plan](docs/plans/2026-11-09-followups.md) record implemented milestones.
The [practical report-query plan](docs/plans/2026-11-09-language-summaries.md)
tracks shorthand, container functions, relative indexes/slices and scalar array
transformations motivated by real acceptance/compiler sessions.
The [automation plan](docs/plans/2026-11-10-automation.md) adds shell gates,
external arguments, batch input/provenance, quantified predicates and statistics.
The [scalar-aggregate plan](docs/plans/2026-11-10-scalar-aggregates.md) adds totals,
grouping and sorting inside report fields in response to workflow qualification.
The [remaining-workflow plan](docs/plans/2026-11-10-remaining-workflows.md) closes
serialization, immutable configuration-edit and structural-schema gaps, then
measures Debug phases before selecting optimizations. `input.zig` owns the same
strict parser used by feeds and phase profiling; `tools/fixtures.zig` shares
deterministic scale data with qualification. The separate profiling module has
internal engine access without extending the public query API. Its allocator
meter wraps successful requested capacity, preserves phase start/end baselines,
and checks zero live bytes after cleanup. Timed execution follows public stream
order, separating parsed-document release before completion, and includes
emission to an allocating writer. Input IO, expectations and report allocations
are excluded.
Tiny CLI measurements include supervision/capture rather than isolating loader
startup. Raw samples, source/input/tool hashes and environment describe the scope.

The complete-input value builder keeps the standard Scanner, arena owner and
end-of-document checks while borrowing plain token text. Decoded escapes and
containers remain arena-owned. Up to four object fields are buffered on the
stack, duplicate-checked after their values, then stored in one exact-capacity
map with its public index rebuild. Larger objects use ordinary map growth.
For documents of at least 64 KiB, a 16 KiB reservation is immediately released
back to the arena for reuse, bounding initial capacity while reducing tiny
growth/fragmentation. Parsed input still lives through synchronous feed; retained
values own copies. No installed standard-library code was changed.
Arrays first buffer sixteen values on the stack. For a larger array, allocating
children in that prefix or the first spill item select caller-allocated temporary
chunks, bounded to 1,024 values each, then one exact arena-owned array. Chunks are freed on success
and failure. Otherwise the array uses ordinary arena growth after the prefix,
avoiding a final duplicate for flat nonallocating inputs. The standard
Parsed arena owner receives the caller allocator through an explicit source
adapter; no allocator is recovered from Scanner internals. Profiling separates
temporary/scanner traffic, logical arena requests and backing totals. Observation
points specialize away in ordinary execution.
Query `keys` and `map` results reserve their known final value count exactly.
Filtering retains its existing upper-bound reservation. This reduces temporary
capacity without changing evaluation order, paths or retained-value budgets.
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
