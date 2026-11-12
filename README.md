# zig-json-query

A standalone Zig 0.17.0 prototype of a JSON query language inspired by jq.
The executable is called `jqz`.

The language keeps field paths and pipelines and makes stream expansion
explicit. Expressions produce one value, `each` expands an array, and
`where(boolean)` keeps or drops the current record. There are no implicit
Cartesian products between expression results. A session spans the whole input
stream, with explicit aggregation, sorting, grouping and early termination.

## Build and try

The release target is x86_64 Linux. Additional architectures will be considered
when there is a concrete deployment requirement.

Use the default Debug mode for routine builds and tests. Check one mode per
change; other optimization modes are reserved for explicit requests or a
specific issue that requires them.

Dependencies are immutable source archives in `vendor/`, pinned by Zig hashes.
No sibling checkout or network download is required. The regex package supplies
matching; test-support supplies native CLI acceptance and benchmark helpers.
The shared package-version CLI supplies developer version synchronization.

```sh
cd ~/prog/zig-json-query
zig build
zig build test

./zig-out/bin/jqz \
  '.users | each | where(.age >= 18) | {name: .name, enabled: .enabled? ?? true, id: .id}' \
  examples/users.json

./zig-out/bin/jqz --ndjson \
  'where(.level == "error") | .message' examples/events.ndjson

./zig-out/bin/jqz --ndjson \
  'where(.level == "error") | count' examples/events.ndjson

./zig-out/bin/jqz \
  '.users | each | take(2) | .name | collect' examples/users.json

./zig-out/bin/jqz -f examples/adults.query examples/users.json

./zig-out/bin/jqz -r \
  '.users | each | sort_by(.name) | .name' examples/users.json

./zig-out/bin/jqz \
  '.users | each | .age | sum' examples/users.json

./zig-out/bin/jqz -f examples/report-summary.query examples/acceptance-report.json

./zig-out/bin/jqz -f examples/recent-commands.query examples/compiler-commands.json

./zig-out/bin/jqz -n --arg name artifact --arg path out/artifact \
  --arg sha256 hash-a --argjson bytes 42 -f examples/artifact-record.query
```

The first command emits:

```json
{"name":"Ada","enabled":false,"id":9007199254740993}
{"name":"Cy","enabled":true,"id":9007199254740995}
```

Supply input filenames in order; omit them or use `-` to read stdin once. Output is compact JSON, one
value per line. `--ndjson` parses each nonblank input line as one JSON value and
feeds it into one shared pipeline session. Output is flushed after each
record; aggregates emit at stream completion. CRLF and a final line without a
newline work. The count example emits `2`; the collection example emits
`["Ada","Ben"]`.
The default mode accepts exactly one JSON document per file, including multiline JSON.
All files feed one session, so `count`, `sum`, `collect`, sorting and grouping span
files. Satisfied `take` skips later records and files without opening them.
`--` ends option parsing, for example `jqz -- '-2' input.json`.

`-r` / `--raw-output` writes strings without JSON quotes; non-strings remain
compact JSON. Each value has a trailing newline, and newlines inside a raw
string remain literal. `-j` / `--join-output` implies raw strings and suppresses
the trailing newline for every result, including JSON values. Embedded newlines
and NUL bytes remain unchanged. `-e` still classifies emitted values, so an empty
joined string is a successful output even though it writes zero bytes.
No-argument short flags `n/s/r/j/S/e` can be bundled, for example `-nj`, `-jr`
or `-nSje`; keep argument-taking options such as `-f` separate.
Stdout and stderr preserve the current position of inherited descriptors, so
sequential invocations inside one redirected shell group append in order.

`-f FILE` / `--from-file FILE` reads one query file;
positional arguments then name input files. Options can precede or follow
positional arguments until `--`. Multiple `-f` options are errors. `-f -` reads
the query from stdin and requires explicit named input files, without `-` input,
unless `-n` is set.
Query files have the same 64 KiB text limit.
`--version` prints the package version.

`-n` / `--null-input` runs the query with one anonymous null value, so arguments
can construct JSON without an input file or stdin data. Data filenames (including
`-`) are ignored, and `--slurp` / `--ndjson` have no effect in this mode. Query
files and bindings are still read/validated; `-n -f -` reads only the query from
stdin and needs no data filenames. Normal completion, output options, early
stopping and `-e` status apply. For example, `jqz -n 'count'` emits `1`, while
`jqz -n -e '.'` emits null and exits 1. Diagnostics label synthetic input `<null>`.
The [null-input implementation plan](docs/plans/2026-11-11-null-input.md)
records the behavior and its workflow qualification.

The [real compiler-workflow audit](docs/qualification/zllvm-usage-2026-11-11.md)
checks translations of `z_llvm` jq usage on retained reports. The
[compiler query examples](examples/zllvm/README.md) cover command summaries,
census progress and grouped rejections, with explicit notes on raw-output and
numeric differences.
The [CLI output/file-binding plan](docs/plans/2026-11-11-cli-output-and-file-bindings.md)
records joined output followed by named JSON/text file bindings.
Its [qualification report](docs/qualification/cli-output-and-bindings-2026-11-11.md)
records five byte-identical live checks and the unchanged 45-case corpus at
0.30.0.

`input_filename()` returns the current input filename as supplied, or `<stdin>`
for CLI stdin. Completion aggregates, null input and slurped input have no unique
filename and return null. Capture provenance before aggregation:

```sh
./zig-out/bin/jqz -f examples/batch-reports.query \
  examples/acceptance-report.json examples/acceptance-passed.json
```

`-s` / `--slurp` collects all input values into one array and runs the query once.
Use `--ndjson -s` to collect records across files; empty NDJSON produces `[]`.
One-document-per-file and per-line limits still apply. Slurp owns its values and
array capacity within a separate budget (64 MiB by default), and nesting includes the wrapper
array. It validates all sources before evaluation, except queries such as
`take(0)` that need no input. A later source error produces no slurped result.
For example, `jqz -s 'length(.)' first.json second.json` emits `2`.
Library callers can use `Stream.feedNamed(input, filename)` for borrowed source
metadata and `Slurp.init(allocator, max_bytes)`, `append(input, diagnostic)`, then
`Stream.feedSlurp(collector)` for an owned array. A collector failure poisons it;
deinit the collector after feeding, and finish/deinit the stream as usual.

`zig build` installs only `jqz`. The repository and source archives use
`zig-json-query`.

Exit status is 0 for success (including zero matches) and 2 for any error.
With `-e` / `--exit-status`, successful completion returns 1 when the last
emitted value is false or null, 4 when nothing was emitted, and 0 otherwise.
Zero, empty strings/containers and raw strings such as `"false"` return 0.
The status uses the JSON value before raw serialization. Errors still return 2
and take precedence over previously emitted values. Output remains unchanged.
For a shell gate, use `jqz -e '.passed and .cleanup_passed' report.json`.
An error stops processing; output produced before the error remains on stdout.
Failed streams discard buffered aggregates instead of emitting partial totals.

## Language

`--arg NAME VALUE` binds `$NAME` to a string. `--argjson NAME JSON` binds it to
one JSON value, preserving exact numbers, false, null and nested containers:

```sh
jqz --arg suite 'compiler-acceptance' --argjson expected false \
  -e '.suite == $suite and .passed == $expected' report.json
```

Arguments are values, so quotes/newlines/query text inside them stay literal.
`--slurpfile NAME FILE` binds an array of every JSON value in a named file;
empty/whitespace-only files produce `[]`. It accepts NDJSON, multiline documents
and adjacent containers/strings while preserving exact number text.
`--rawfile NAME FILE` binds exact UTF-8 text, including newlines and NUL; an empty
file produces `""`, and invalid UTF-8 is rejected. For example:

```sh
jqz -n --slurpfile before old-manifest.json --slurpfile after new-manifest.json \
  -f examples/zllvm/compare-source-files.query
jqz -nj --rawfile text notes.txt '$text'
```

Binding filenames are literal named paths: `-` opens a file named `-`, while
`-f -` can independently read query text from stdin. Query sources are resolved
first; file bindings are then loaded and validated before primary input, even
when unused or combined with `-n` / `take(0)`. All binding kinds share 128 names;
bound source text and prepared value text each have a total 64 MiB limit. JSON
file bindings add an outer array, which counts toward the 128-level depth limit.

Names match `[A-Za-z_][A-Za-z0-9_]*`; duplicate names and unbound variables error.
Variables work inside array-function bodies and query files, and support normal
field/index access. All bindings are validated before input, even when unused.
Admission limits are 128 bindings, 64 MiB total value text, and 128 JSON container
levels; strings must be valid UTF-8, and JSON must have unique object keys.
Library callers use `Program.compileWithBindings(allocator, source, bindings,
diagnostic)` with `Binding{ .name = "x", .value = .{ .json = "false" } }` or a
`.string` value. Compiled programs own the names/data and can outlive caller
buffers. `Program.compile` remains the convenience API without bindings.

| Construct | Meaning |
| --- | --- |
| `.`, `.user.name` | Current value; strict field access |
| `$expected`, `$config.limit` | Typed external value; bound once for the program lifetime |
| `input_filename()` | Current input label, or null when there is no unique source |
| `.["a-b"]`, `.users[0]`, `.users[-1]` | Literal string key; array index, counting from the end when negative |
| `.name?`, `.[4]?` | Allow an absent field or out-of-range index |
| `.commands[-3:]`, `.items[:10]`, `.[1:4]` | One array slice, with an inclusive start and exclusive end |
| `.name? ?? "unknown"` | Default for missing or JSON null only |
| `exists(.name?)` | False for absence, true for any JSON value including null |
| `each` | Expand the current array into an ordered stream of items |
| `where(.age >= 18)` | Keep the record only when the expression is true |
| `count` | Count arriving values and emit one exact integer when the stream ends |
| `collect` | Retain arriving values and emit one array when the stream ends |
| `take(10)` | Forward at most ten values, then stop upstream processing |
| `sum` | Sum arriving integers and emit one exact integer; `0` for empty input |
| `sum(.items)` | Sum one array of integers inside an expression; `0` for an empty array |
| `sort`, `sort_by(.age)` | Buffer records, then emit them in stable ascending key order |
| `group_by(.team)` | Emit one array per equal key, in first-seen key order |
| `sort_by(.items, .age)` | One stably sorted array, with `.` bound to each item for its key |
| `group_by(.items, .team)` | One array of groups, in first-seen key order |
| `sort_values(.items)` | One stably sorted array using a total structural JSON order |
| `unique(.items)` | Distinct structural values in sorted order, keeping first equal representatives |
| `{name: .name, age: .age}` | Construct one object |
| `{name, age, count: length(.items)}` | Shorthand strict fields mixed with computed values |
| `[.name, .age]` | Construct one array; does not collect a stream |
| `length(.items)` | Array element count, object field count, or string Unicode scalar-value count |
| `tojson(.value)` | Compact JSON text as a string, preserving exact number tokens |
| `byte_length(.text)` | UTF-8 byte count of a string |
| `update(., .groups, filter(., .keep))` | Replace an existing path with a body evaluated on its selected value |
| `del(., .debug)` | Remove an existing field or array item, preserving other values |
| `keys(.)` | Sorted object names, or ascending array indexes |
| `map(.items, {name, id})` | One ordered array of results, evaluating the body with each item as `.` |
| `filter(.items, .code != 0)` | One ordered array of original items whose boolean predicate is true |
| `all(.checks, .ok)`, `any(.checks, .ok)` | One boolean; short-circuiting quantified predicates |
| `mean(.samples, 6)` | One bounded decimal mean with six fractional digits; null for an empty array |
| `divide(.ns, 1000000, 6)` | Explicit bounded decimal division with six fractional digits |
| `==`, `!=`, `<`, `<=`, `>`, `>=` | Equality and ordering comparisons |
| `and`, `or`, `not` | Strict boolean logic; `and` and `or` short circuit |
| `+`, `-`, `*`, `/`, `%`, unary `-` | Checked exact signed 128-bit integer arithmetic |
| `matches(.name, "(?i)^a")` | Search using a constant regex compiled once |
| `# comment` | Comment until end of query line |

Strings use JSON double quotes and escapes. Quoting the whole query with shell
single quotes usually keeps those strings intact. Parentheses group expressions.
Precedence, low to high: `??`, `or`, `and`, equality, ordering, `+`/`-`,
`*`/`/`/`%`, `not`/unary `-`, access.
`??` associates to the right; other binary operators associate to the left.
Pipes separate stages and cannot appear inside scalar expressions.

Container functions can be used inside expressions and object fields:

```text
{passed, cleanup_passed, requests: length(.http), fields: keys(.result)}
.http | each | group_by(.status) | {status: .[0].status, count: length(.)} | collect
```

`{passed}` is shorthand for `{passed: .passed}`; quoted names work too:
`{"a-b"}` reads `.["a-b"]`. Shorthand remains strict about absent fields.
Use an explicit field such as `{result: .result? ?? null}` for a default.
`length` counts Unicode scalar values in strings, so `"é😀"` has length `2`;
combining characters count separately. `keys` sorts object names by UTF-8 bytes
and returns `[0,1,...]` for arrays. Empty containers have length `0` and keys
`[]`. Unsupported types and unhandled missing arguments error; use, for example,
`length(.http? ?? [])` to handle an optional array. `length` counts one container;
the `count` stage counts values arriving through the stream.

Array indexes and slice bounds are integer literals, with an optional minus
sign and magnitude fitting `usize`. `[-1]` selects the last element, and `[-0]`
selects index zero. An out-of-range index errors unless followed by `?`, for
example `.http[-1]? ?? null` on an empty array. Slice bounds clamp to the array:
omitted bounds mean the beginning/end, `[:]` selects the whole array, negative
bounds count from the end, and reversed bounds produce `[]`. A slice always
exists for a present array; a following `?` has no effect. Slices accept arrays,
not strings. Optional indexes/slices still reject a wrong container type, and
missing bases propagate. Dynamic indexes and slice steps are unsupported.

```text
{commands: length(.), recent: .[-3:], last: .[-1]? ?? null}
```

`map(array, expression)` and `filter(array, predicate)` evaluate their first
argument once, then bind `.` to each element for the second argument. They return
one array and can nest inside objects and other functions:

```text
{
  passed,
  cleanup_passed,
  requests: length(.http),
  last_request: .http[-1]? ?? null,
  failures: map(filter(.fixtures, .result.code != 0), {case, code: .result.code})
}
```

`map` requires a nonmissing result per element; false and null are valid results.
`filter` requires a boolean and keeps the original matching elements. Both
preserve order, reject non-array inputs, skip the body on empty arrays, and
restore the surrounding context after nested calls. Optional defaults stay
explicit. Arrays are materialized within the current expression stage; `each`
explicitly expands an array into a stream. There is no outer-scope variable
binding inside a body. `map`/`filter` are language functions, not jq-compatible
generator expressions; pipes still separate top-level stages.

`all(array, predicate)` and `any(array, predicate)` bind items in the same way.
`all` stops at the first false predicate and `any` at the first true one; later
predicates are skipped. Evaluated predicates require booleans. Empty `all` is
true and empty `any` is false. They return a boolean without another array.
To require every report to pass, run:

```sh
./zig-out/bin/jqz -s -e -f examples/qualify-reports.query examples/acceptance-passed.json
```

The query file contains `all(., .passed and .cleanup_passed)`; adding a failed
report makes the gate print false and exit 1.

Important semantic choices:

- `.absent` is an error. `.absent?` produces an internal missing value, which
  must be handled before emission, comparison, or object/array construction.
  `.absent ?? 0` still errors; use `.absent? ?? 0`.
- Missing is distinct from JSON null. `exists(.x?)` distinguishes them.
- `??` preserves `false`, `0`, empty strings, and empty containers. Its right
  operand is evaluated only when needed.
- Optional access allows absence, not a wrong container type. `.contact?.email`
  propagates a missing contact, but a contact explicitly set to null causes a
  type error when accessing its email.
- `where` requires a boolean. Ordering requires two numbers or two strings;
  it does not impose an arbitrary order across JSON types. Equality between
  different types is false. Objects compare independently of key order; arrays
  compare in order. Strings use UTF-8 byte order without normalization.
- Number tokens are preserved exactly. Comparison uses decimal digits and
  exponents, so `9007199254740993` is different from `9007199254740992`, while
  `1`, `1.0`, and `1e0` compare equal. Arithmetic has a separate bounded integer
  contract below and never silently converts through floating point.
- Duplicate object keys are rejected in both input JSON and query objects.

## Stream scope and completion

`count`, `collect` and `sum` consume all values arriving at their position in the
pipeline. They emit exactly once, including `0` and `[]` for an empty stream.
In document mode `count` counts one document; `each | count` counts its array
elements. In NDJSON mode `count` counts all nonblank input records. `sum` adds
the arriving numbers, so `.amount | sum` aggregates an NDJSON field.

`take(n)` accepts a nonnegative integer literal fitting u64. It stops upstream
evaluation after `n` values, while downstream aggregates still finish:

| Query | Result for input records `1`, `2`, `3` |
| --- | --- |
| `take(2) | collect` | `[1,2]`, without waiting for source EOF |
| `take(2) | where(false) | count` | `0` |
| `count | take(1)` | `3`, after source EOF |
| `collect | each | take(2) | count` | `2`, after source EOF |
| `take(0) | count` | `0`, without reading input |
| `count | take(0) | collect` | `[]`, without reading input |

End-of-stream signals propagate in pipeline order, so `count | collect` on empty
input produces `[0]`, and `collect | collect` produces `[[]]`.
An aggregate's output can be filtered, projected or expanded like any other
value. `count`, `collect`, `sort` and `take` are stream stages. Bare `sum` and
one-argument `sort_by(key)` / `group_by(key)` are stream stages. `sum(array)`
and two-argument `sort_by(array,key)` / `group_by(array,key)` are scalar functions.

`sum(array)` evaluates its argument once and adds its elements in array order.
It uses the same checked integer rules as the stream stage, including overflow
of an intermediate total. It works inside summary objects without discarding
other report fields:

```text
{status, reviewed_moves: sum(map(.artifact_differences, .changed_moves))}
```

An empty array gives `0`. Nonarrays, missing values, nonnumeric or fractional
elements and values outside i128 fail. Element errors identify the original array
index when its source path is available.

Skipped records are not validated, and errors in skipped upstream expressions
are not evaluated. Buffered IO may already have read ahead. Except for queries
that need no input, document mode still reads and parses a whole JSON document
before evaluating it; `take` does not make document parsing incremental.

## JSON text and sizing

`tojson(value)` encodes one JSON value as a compact string, without a trailing
newline. Object insertion order and exact number tokens are preserved. Unicode
text remains UTF-8; quotes, backslashes and control characters are escaped.
Encoding is subject to the existing 128-container limit, even when its final
result is a shallow string. Missing values require an explicit default.

`byte_length(string)` counts UTF-8 bytes; `length(string)` counts Unicode scalar
values. For `"é😀"`, those lengths are 6 and 2; its JSON text includes two quotes
and has 8 bytes and 4 scalar values. Escapes count as their encoded characters.
For actual serialized sample bytes, use:

```text
{air_roots, sample_bytes: byte_length(tojson(.samples[0]))}
```

`-r 'tojson(.)'` writes the compact text directly, followed by the ordinary CLI
output newline, which is not included in `byte_length(tojson(.))`.

## Immutable path edits and sorted output

`update(value, path, body)` selects an existing value and replaces it with the
body's result. The body sees that selected value as `.`; nested array functions
and external bindings work normally. `del(value, path)` removes a selected
object field or array element. Both copy ancestor containers and preserve all
other fields, insertion order, number tokens and array order without mutating
the input. For a configuration whose other fields must survive:

```sh
./zig-out/bin/jqz -S --arg remove calendar.journey \
  'update(., .groups, filter(., .id != $remove))' config.json
```

Paths start with `.` and contain at least one literal field/index. Quoted fields
and negative indexes work, for example `.groups[-1]["a-b"]`. Missing targets,
wrong containers and missing replacement values fail with source paths. Optional
access, slices and computed selectors are not edit paths. `del` of an absent
field is an error; use an explicit presence check before choosing to edit.

`-S` / `--sort-keys` recursively sort output object names by UTF-8 bytes, keeping
array order and number spelling. JSON remains compact; raw strings are unchanged,
and keys inside already encoded `tojson` strings are not reordered. Library
callers select this using `StreamOptions.sort_keys`. Sorting uses temporary
storage outside the retention budget; retained edit results use the ordinary
shared budget and ownership rules.

## Integer arithmetic

Arithmetic operands and results must fit signed 128-bit integers, from
`-170141183460469231731687303715884105728` through
`170141183460469231731687303715884105727`. Integral decimal/exponent spellings
such as `1.0`, `0.001e3`, and `1e3` are accepted. Fractional operands, wrong
types, out-of-range operands and overflow are located errors. Results serialize
as canonical integer tokens. This range applies to `sum` too.

Division must be exact: `6/3` is `2`; `1/2` errors. There is no implicit rounding,
truncation, floating-point fallback or coercion from strings/booleans. Division
and remainder by zero error. Remainder has the dividend's sign (`-7%3` is `-1`).
Negative numeric literals still preserve arbitrary valid decimal tokens for
passthrough/comparison; applying arithmetic requires the integer contract.

## Decimal statistics

`mean(array, PLACES)` and `divide(lhs, rhs, PLACES)` provide explicit fractional
statistics. `PLACES` is a required constant integer from 0 through 18. Results
round to nearest with ties to even and contain exactly that many fractional
digits. For example, `divide(1,8,2)` is `0.12`, `divide(3,8,2)` is `0.38`, and
`mean([1,2],3)` is `1.500`. Negative zero becomes ordinary zero at the selected
precision. Empty means return null. All other operands must be numbers; missing
values, division by zero and unsupported ranges are located errors.

These calls use bounded exact decimals: after trimming insignificant trailing
zeros and applying exponents, the coefficient must fit signed i128 and its
fractional scale must be at most 18. The rounded coefficient at the requested
precision must also fit i128. Wide integer intermediates align/sum values
exactly and round once per call, without floating point. Existing arbitrary
decimal comparison/passthrough and integer `+ - * / %` / stream `sum` keep their
contracts. In particular `/` still requires exact integer division.

Convert integer nanoseconds to milliseconds at six places before averaging;
that conversion is exact, and the mean then rounds the final result:

```sh
./zig-out/bin/jqz -f examples/timing-summary.query examples/timings.json
```

The query uses `mean(map(.sample_elapsed_ns, divide(.,1000000,6)),6)` and emits
`{"samples":3,"mean_ms":2.000002}`. This composition also handles empty samples
with a null mean. Fractional results support exact comparisons with thresholds
supplied through `--argjson`.

## Sorting and grouping

`sort` uses each record as its key. `sort_by(expr)` evaluates one key per record
and retains owned copies of keys and records. All sort keys must be numbers or
all must be strings. Exact decimal comparison and UTF-8 byte ordering apply;
mixed types, missing keys, and unsupported numeric exponents error. Equal keys
preserve input order. Results are emitted individually at stream completion;
append `| collect` to produce one sorted array. Empty input emits nothing.

`group_by(expr)` uses structural JSON equality: numeric spellings normalize,
objects ignore key order, and arrays retain order. Each output is one array of
records with equal keys. Groups appear in first-seen key order; records within
a group retain input order. Missing keys error. Empty input emits nothing.
Unlike jq's `group_by`, this stage does not sort groups by their keys.

`sort_by(array, key)` and `group_by(array, key)` provide the same key rules and
ordering inside scalar expressions. They evaluate the array once, then evaluate
each key once with `.` bound to that item, restoring the caller's scope afterward.
Both return one array, including `[]` for empty input, which does not evaluate
the key expression. Scalar grouping returns an array of group arrays. Original
item values and number tokens are preserved; missing keys require an explicit
default. Source paths identify failing key expressions when available.

To retain report context and match jq's ascending status-group order, sort the
constructed summaries explicitly:

```text
{
  passed,
  statuses: sort_by(
    map(group_by(.http, .status), {status: .[0].status, count: length(.)}),
    .status
  )
}
```

Both stages share the collection budget and the existing ownership, error,
early-stop and ordered-completion contracts. A downstream `take(0)` avoids
reading input; a positive downstream limit still requires source completion.
Sorting is stable and in-place after buffering; grouping uses a quadratic scan
of keys. The scalar forms reuse these algorithms with temporary rows and keys.
There is no spill-to-disk fallback.

`sort_values(array)` and `unique(array)` support structural ordering separately
from the stream stages. The total order is null, booleans (false before true),
numbers, strings, arrays, objects. Arrays compare lexicographically. Objects
compare their sorted key sequences, then corresponding values; field insertion
order does not affect comparison. Numeric comparisons stay exact. Both return
`[]` for empty input and reject missing/nonarray inputs, excessive comparison
depth and unsupported numeric exponents.

`sort_values` is stable. `unique` sorts and removes equal adjacent values,
preserving the first original representative's number spelling and field order.
For sorted distinct schemas, use `unique(map(.fixtures, keys(.)))`. Comparison
preparation borrows already ordered trees and copies only changed ancestor
containers into the scalar arena. Unique rows compact before reserving output
capacity, so duplicates do not reserve result slots. Output items borrow the originals until retained
or synchronously emitted. The existing stream `sort` and `sort_by` still require
uniform numeric/string keys.

## Scope and limits

This is a tested prototype, not a jq-compatible replacement or a finished CLI.
It currently lacks local bindings, user-defined functions,
general assignment, general reduction, disk spilling, and a REPL.
The syntax and library API may change.

NDJSON is parsed one record at a time. A single JSON document is parsed in full
with `std.json`. Ordinary stages emit immediately; `count` keeps a checked u64
counter, and `collect` retains owned copies until completion. Incremental parsing
within one large document is a separate planned feature. The benchmark harness
records output equivalence, elapsed time and child peak RSS; see
[benchmark evidence](docs/benchmarks/README.md). These measurements do not
establish a general performance advantage over jq.

All retaining stages in a session share a default 64 MiB limit on live retained allocator
requests, including arena/container capacity. Library callers can override it
with `StreamOptions.max_collect_bytes`. This is not a process RSS limit: input
parsing, scalar temporaries, writer buffers and allocator metadata are separate.
Materialized `map`/`filter` arrays, `keys` results and scalar sort/group rows,
keys and arrays use those scalar-stage temporaries. Retaining their results charges
the existing shared budget and copies borrowed input values.
Retained sort/group keys and grouping scratch count too. Passing values between retaining stages
temporarily retains both copies within that shared budget. A limit failure
reports the responsible stage in the query.
System allocation failures remain `OutOfMemory`. No spill-to-disk is implemented.

CLI `--max-retained-bytes N` overrides the shared retained capacity, and
`--max-slurp-bytes N` independently overrides owned slurp capacity. Both accept
unsigned decimal bytes fitting the platform `usize`; zero permits no allocations,
with no unlimited sentinel or suffixes. Input text, query/bindings, parsed input,
scalar temporaries, output buffers and allocator metadata keep their separate
limits/lifetimes. A document below the 64 MiB text limit can exceed the slurp
budget after parsing and copying its containers. Budget errors report the
configured limit, live retained capacity and requested allocation size; they
suggest raising the applicable option or avoiding unnecessary `-s`.

```sh
jqz --max-retained-bytes 134217728 --ndjson 'sort_by(.path)' records.jsonl
jqz --max-slurp-bytes 268435456 -s 'length(.)' first.json second.json
```

Admission limits: 64 KiB query text, 4096 expression nodes, 128 pipeline stages,
128 expression nesting levels, 128 input container levels, 64 MiB per document,
and 1 MiB per NDJSON line. Output/comparison nesting is also checked. Numeric
comparison exponents and their adjusted digit positions must fit signed 64-bit
integers; numeric passthrough does not require that conversion. Regex patterns
are limited to 1024 bytes and 4096 emitted instructions, not a wall-clock bound.
Regex syntax follows `zig-regex`; lookaround and backreferences are unsupported.

Query errors have a source filename, line/column and caret. Input syntax errors
have the input filename, line/column and a bounded source excerpt, using Zig's
JSON scanner position. Runtime failures identify the file and NDJSON line;
completion failures use `:EOF:`. Evaluation diagnostics track JSON paths through
field/index projection and `each`. Constructed values and buffered aggregate
outputs have no unique source path. Paths are bounded to 1024 bytes with explicit
truncation; columns count bytes. Native CLI acceptance is tested on Linux.
Array-function body errors include the source element index when the argument
has a known source path. Slices and computed arrays clear that provenance.

## Reused packages

The inventory at `~/zig-inventory-2026-11-03/` identified existing providers.
Current source and APIs were inspected before adoption.

| Provider | Used for | Inspected revision |
| --- | --- | --- |
| `../zig-regex` 0.2.0 | Compiled `matches` expressions | `65e304effed8e58e5ca09a39104f8c24e28fc312` |
| `../zig-test-support` 0.2.0 | CLI stdin, output capture, exit/error assertions, temporary-file helpers | `f0f54d4e8cb649af7673ca498f259b6b2f9aa25e` |
| `../zig-package-version` 0.1.0 | Release version validation and synchronization | `3b35ef146e0308b9aa0f61f27e95ae8c7f143a15` |

These revisions are pinned source archives with hashes, licenses and provenance
in [vendor/README.md](vendor/README.md). Test support uses its existing vendored
`zig-process`. Provider source was not modified. Scripty was considered, but its
host-defined field/call grammar does
not supply this language's pipeline and operator grammar. The parser here is
small and language-specific. JSON tokenization and syntax validation use the
installed standard-library Scanner. A complete-input value builder borrows plain
token text, owns decoded escapes/containers in the parsed arena, and checks
duplicate decoded keys. It buffers small objects before allocating their map
once and uses a bounded 16 KiB arena reservation for documents at least 64 KiB.

## Library and checks

`zig build qualify -- --repeat 5 --out .zig-cache/qualification/local.json`
checks the sanitized session-derived workflow corpus against installed jq 1.7,
then records native Debug wall-time and peak-RSS samples for equivalent cases.
The [qualification report](docs/qualification/README.md) separates selected-case
coverage, unsupported jobs, semantic differences and generated scale checks.
Reproduction uses repository data, not private session storage.

`build.zig` exports the `query` module. `Program.compile(allocator, source,
&diagnostic)` owns its query text, AST and compiled regexes; call `deinit` once.
`program.run(allocator, json_bytes, writer, &diagnostic)` remains a one-document
convenience that starts, feeds, finishes and releases a session.

For a stream, call `program.start(allocator, writer, &diagnostic, options)`, then
`stream.feed(json_bytes)` for each input value while `stream.needsInput()` is
true. `feed` returns whether another record is needed. On source EOF or an early
stop, call `stream.finish()`. Always call `stream.deinit()` once, including on
failure or abandonment. Deinitialization itself never emits output.

Input bytes can be released or reused after `feed` returns. Collectors deep-copy
containers, keys, strings and exact number tokens. Finishing twice is a no-op;
feeding a finished session returns `StreamFinished`. Input, evaluation, budget
or writer errors poison the session and discard retained collections; subsequent
feed/finish calls return `StreamFailed`. Do not finish a session after a source IO
error; deinitialize it. A feed after `take` has stopped (before finish) returns
false without parsing the supplied bytes.

Program storage, the writer, diagnostic and allocators must outlive the session.
The caller owns writer flushing. Sessions have independent state; do not share a
writer or diagnostic concurrently without coordination. Regex matching uses the
program's allocator, so concurrent sessions require an allocator suitable for
concurrent use.

```sh
zig build test-unit
zig build test-unit -Dtest-filter=stream
zig build test-cli
zig build test-file-bindings
zig build test-package-version
zig build check
zig build fuzz -Dfuzz-target='fuzz parser' --fuzz=10000
zig build fuzz -Dfuzz-target='fuzz evaluator' --fuzz=10000
zig build dist
zig build test-verify-dist
zig build verify-dist
zig fmt --check build.zig build.zig.zon src tests tools
```

Tests cover the semantic differences, shared regex behavior, exact numbers,
query ownership, invalid input, source diagnostics, input limits, and injected
allocation failures. Stream tests cover aggregate scope, ordered completion,
early stopping, independent sessions, retained-value ownership, memory budgets,
error cleanup and output failures. CLI tests execute the actual binary through
the existing test-support package and verify early exit with stdin still open.
Generated checks compare stream compositions, decimal comparisons, integer
arithmetic, stable sorting and grouping order with independent reference models.
Fault injection covers every allocation in a sorting/grouping/arithmetic handoff.
The separate `tests/package` consumer checks the exported module boundary.
The [scalar-aggregate plan](docs/plans/2026-11-10-scalar-aggregates.md) records
implementation and qualification of report totals and grouped summaries.
The [remaining-workflow plan](docs/plans/2026-11-10-remaining-workflows.md) tracks
serialization, immutable edits, structural distinctness and Debug profiling.

`zig build profile -- --repeat 10 --out .zig-cache/profile.json` measures query
compilation, session setup, strict parsing, feed/evaluation, document release,
stream completion/output and cleanup on sanitized small and generated scale
inputs. It checks
every result against ordinary public execution and requires zero tracked live
bytes after cleanup. Per-phase allocator requests and live-byte peaks measure
requested capacity, not RSS. Supervised null-input CLI samples include process
launch, IO capture and scheduling. Inputs are preloaded and caches warmed; these
native Debug measurements guide investigation and do not establish optimized
performance. `zig build test-profile` checks the profiler and allocation meter.
The [profile report](docs/profiling/README.md) records measurements, limits and
the original experiments suggested by them. The completed
[performance report](docs/profiling/performance-2026-11-11.md) records the accepted
parser/structural improvements and matched original/current CLI comparisons.
The [parser/runtime performance plan](docs/plans/2026-11-11-parser-and-runtime-performance.md)
records those completed experiments and measured optimization steps.
The [container-construction follow-up](docs/plans/2026-11-11-container-construction.md)
records completed current-builder and materialization work; its
[report](docs/profiling/container-construction-2026-11-11.md) separates accepted
memory reductions from rejected sorting experiments and matched CLI results.
`zig build profile -- --study parser --repeat 14 --out .zig-cache/parser.json`
separates depth/scanner experiments, standard DOM allocation traffic and matched
full-parser controls. Scanner experiments overlap full parsing; they are not
additive timings or duplicate-key validation. Logical token/container requests
are reported separately from backing arena capacity.
`zig build profile -- --study builder --repeat 12 --out .zig-cache/builder.json`
compares the frozen 0.22.0 builder and current parser with paired controls, then
observes token/container operations with counters alone and with clocks. Narrow
operation timings include probe overhead; acceptance uses ordinary full parses.
Temporary caller-allocator requests are separate from parsed-arena logical
requests; backing peaks include both owners.
`zig build profile -- --study collections --repeat 12 --out .zig-cache/collections.json`
compares frozen/current known-size storage and structural sorting on eight
distributions. Models omit AST/path traversal; separate actual source/full-query
intervals preserve those costs. Six-variant order also balances predecessors.
`zig build profile -- --study invocation --repeat 12 --out .zig-cache/invocation.json`
compares native Debug launch controls, repeated processes, multi-file/NDJSON
batching and compiled-Program reuse. An optional `--reference-cli PATH` pins an
older CLI for the null-query control. Child memory is unavailable in these
supervised intervals and is reported as null rather than zero.
Supplying the reference also compares the two large generated documents through
both real CLIs, with balanced current/reference controls and exact outputs.
Backend key-array materialization and schema uniqueness are included as well.
`zig build profile -- --study structural --repeat 10 --out .zig-cache/structural.json`
measures source/key materialization, comparison preparation, sorting, reservation
and deduplication on repeated, distinct, mixed and nested inputs. Full-query
controls check the component model against the actual evaluator.
`zig build dist` creates a deterministic source archive in `zig-out/dist`, with
dependencies included and build caches excluded; it requires GNU tar.
The completed [standalone-package plan](docs/plans/2026-11-11-standalone-package.md)
and [earlier package checkpoint](docs/qualification/2026-11-11-package-evidence.json) record
byte-identical archive rebuilds, fresh extracted-source checks and an independent
consumer for 0.26.2, plus practical report/configuration queries checked against jq.
`zig build verify-dist` automates archive reproducibility/content checks, fresh
source tests/build, a one-repetition corpus replay and the separate consumer.
It uses native x86_64 Linux Debug and the existing Zig, Git, GNU tar/gzip/coreutils,
jq 1.7 and GNU time tools. Evidence defaults to `zig-out/verify-dist/evidence.json`;
each run retains its archive, CLI, manifest, corpus JSON and bounded command logs
beside that file. Use `-- --out FILE --timeout-ms 600000` to choose another report
or per-command deadline. Output must be under `zig-out` or outside the checkout,
with no symlink ancestors. A failed check stops dependent work, exits nonzero and
records the failure; cleanup errors prevent a verified result. Only its marked
temporary workspace is removed. `zig build test` includes the focused verifier
tests and never launches full qualification. The
[implementation plan](docs/plans/2026-11-11-verify-dist.md) records the stages.
The [automated checkpoint](docs/qualification/2026-11-11-verify-dist-evidence.json)
qualifies 0.27.1: 228 source tests, all 45 corpus cases, eight consumer checks,
identical archives and successful cleanup. The
[qualification report](docs/qualification/README.md) records the frozen snapshot,
artifact hashes, raw logs and an intentional timeout check.

See [DESIGN.md](DESIGN.md), the completed
[stream plan](docs/plans/2026-11-09-stream-runtime.md), the
[follow-up plan](docs/plans/2026-11-09-followups.md), and the
[qualification report](docs/validation-2026-11-09.md) for contracts and checks
actually executed. Comparative measurements use pinned jq and jaq binaries;
jaq was acquired separately because it was absent from the initial inventory.

## Version workflow

```sh
zig build version
zig build version -- get
zig build version -- set 0.3.1
zig build test-package-version
```

The `version` step runs the pinned `zig-package-version` CLI using
[`tools/versions.json`](tools/versions.json). `build.zig.zon` is authoritative;
reading checks that the library version, both source archive names and the
benchmark's expected CLI version match it. Setting a canonical numeric
`MAJOR.MINOR.PATCH` prepares all five marked replacements before writing and
preserves dependency pins and historical benchmark/validation records. The
shared tool owns validation, per-file atomic updates and rollback. Bump decisions
remain in [AGENTS.md](AGENTS.md): agents use patch increments for compatible fixes
and minor increments for compatible features; major changes belong to the user.

`zig build test` includes four integration checks using temporary copies of the
real configured files: get/set synchronization, mismatch reporting/repair,
invalid version rejection and failed preflight without partial writes.
