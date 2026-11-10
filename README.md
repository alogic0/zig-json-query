# zig-json-query

A standalone Zig 0.17.0 prototype of a JSON query language inspired by jq.
The executable is called `json-query`; both names are provisional.

The language keeps field paths and pipelines and makes stream expansion
explicit. Expressions produce one value, `each` expands an array, and
`where(boolean)` keeps or drops the current record. There are no implicit
Cartesian products between expression results. A session spans the whole input
stream, with explicit aggregation, sorting, grouping and early termination.

## Build and try

The release target is x86_64 Linux. Additional architectures will be considered
when there is a concrete deployment requirement.

Dependencies are immutable source archives in `vendor/`, pinned by Zig hashes.
No sibling checkout or network download is required. The regex package supplies
matching; test-support supplies native CLI acceptance and benchmark helpers.

```sh
cd ~/prog/zig-json-query
zig build
zig build test
zig build test -Doptimize=ReleaseSafe

./zig-out/bin/json-query \
  '.users | each | where(.age >= 18) | {name: .name, enabled: .enabled? ?? true, id: .id}' \
  examples/users.json

./zig-out/bin/json-query --ndjson \
  'where(.level == "error") | .message' examples/events.ndjson

./zig-out/bin/json-query --ndjson \
  'where(.level == "error") | count' examples/events.ndjson

./zig-out/bin/json-query \
  '.users | each | take(2) | .name | collect' examples/users.json

./zig-out/bin/json-query -f examples/adults.query examples/users.json

./zig-out/bin/json-query -r \
  '.users | each | sort_by(.name) | .name' examples/users.json

./zig-out/bin/json-query \
  '.users | each | .age | sum' examples/users.json
```

The first command emits:

```json
{"name":"Ada","enabled":false,"id":9007199254740993}
{"name":"Cy","enabled":true,"id":9007199254740995}
```

Omit the input filename or use `-` to read stdin. Output is compact JSON, one
value per line. `--ndjson` parses each nonblank input line as one JSON value and
feeds it into one shared pipeline session. Output is flushed after each
record; aggregates emit at stream completion. CRLF and a final line without a
newline work. The count example emits `2`; the collection example emits
`["Ada","Ben"]`.
The default mode accepts exactly one JSON document, including multiline JSON.
`--` ends option parsing, for example `json-query -- '-2' input.json`.

`-r` / `--raw-output` writes strings without JSON quotes; non-strings remain
compact JSON. Each value has a trailing newline, and newlines inside a raw
string remain literal. `-f FILE` / `--from-file FILE` reads one query file;
the sole positional argument then names the input. Options can precede or
follow positional arguments until `--`. Multiple `-f` options or two positional
arguments with `-f` are errors. `-f -` reads the query from stdin and requires
an explicit non-stdin input file. Query files have the same 64 KiB text limit.
`--version` prints the package version.

Exit status is 0 for success (including zero matches) and 2 for any error.
An error stops processing; output produced before the error remains on stdout.
Failed streams discard buffered aggregates instead of emitting partial totals.

## Language

| Construct | Meaning |
| --- | --- |
| `.`, `.user.name` | Current value; strict field access |
| `.["a-b"]`, `.users[0]` | Literal string key; nonnegative array index |
| `.name?`, `.[4]?` | Allow an absent field or out-of-range index |
| `.name? ?? "unknown"` | Default for missing or JSON null only |
| `exists(.name?)` | False for absence, true for any JSON value including null |
| `each` | Expand the current array into an ordered stream of items |
| `where(.age >= 18)` | Keep the record only when the expression is true |
| `count` | Count arriving values and emit one exact integer when the stream ends |
| `collect` | Retain arriving values and emit one array when the stream ends |
| `take(10)` | Forward at most ten values, then stop upstream processing |
| `sum` | Sum arriving integers and emit one exact integer; `0` for empty input |
| `sort`, `sort_by(.age)` | Buffer records, then emit them in stable ascending key order |
| `group_by(.team)` | Emit one array per equal key, in first-seen key order |
| `{name: .name, age: .age}` | Construct one object |
| `[.name, .age]` | Construct one array; does not collect a stream |
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
value. Aggregates, `sort`, `sort_by`, `group_by` and `take` are stages, not scalar
expression functions.

Skipped records are not validated, and errors in skipped upstream expressions
are not evaluated. Buffered IO may already have read ahead. Except for queries
that need no input, document mode still reads and parses a whole JSON document
before evaluating it; `take` does not make document parsing incremental.

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

Both stages share the collection budget and the existing ownership, error,
early-stop and ordered-completion contracts. A downstream `take(0)` avoids
reading input; a positive downstream limit still requires source completion.
Sorting is stable and in-place after buffering; grouping initially uses a
quadratic scan of retained keys. There is no spill-to-disk fallback.

## Scope and limits

This is a tested prototype, not a jq-compatible replacement or a finished CLI.
It currently lacks fractional arithmetic, variables, user-defined functions,
updates, general reduction, disk spilling, and a REPL.
The syntax and library API may change.

NDJSON is parsed one record at a time. A single JSON document is parsed in full
with `std.json`. Ordinary stages emit immediately; `count` keeps a checked u64
counter, and `collect` retains owned copies until completion. Incremental parsing
within one large document is a separate planned feature. The benchmark harness
records output equivalence, elapsed time and child peak RSS; see
[benchmark evidence](docs/benchmarks/README.md). These measurements do not
establish a general performance advantage over jq.

All retaining stages in a session share a 64 MiB limit on live retained allocator
requests, including arena/container capacity. Library callers can override it
with `StreamOptions.max_collect_bytes`. This is not a process RSS limit: input
parsing, scalar temporaries, writer buffers and allocator metadata are separate.
Keys and grouping scratch count too. Passing values between retaining stages
temporarily retains both copies within that shared budget. A limit failure
reports the responsible stage in the query.
System allocation failures remain `OutOfMemory`. No spill-to-disk is implemented.

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

## Reused packages

The inventory at `~/zig-inventory-2026-11-03/` identified existing providers.
Current source and APIs were inspected before adoption.

| Provider | Used for | Inspected revision |
| --- | --- | --- |
| `../zig-regex` 0.2.0 | Compiled `matches` expressions | `65e304effed8e58e5ca09a39104f8c24e28fc312` |
| `../zig-test-support` 0.2.0 | CLI stdin, output capture, exit/error assertions, temporary-file helpers | `f0f54d4e8cb649af7673ca498f259b6b2f9aa25e` |

These revisions are pinned source archives with hashes, licenses and provenance
in [vendor/README.md](vendor/README.md). Test support uses its existing vendored
`zig-process`. Provider source was not modified. Scripty was considered, but its
host-defined field/call grammar does
not supply this language's pipeline and operator grammar. The parser here is
small and language-specific; JSON parsing comes from the installed standard
library.

## Library and checks

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
zig build check
zig build fuzz -Dfuzz-target='fuzz parser' --fuzz=10000
zig build fuzz -Dfuzz-target='fuzz evaluator' --fuzz=10000
zig build dist
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
`zig build dist` creates a deterministic source archive in `zig-out/dist`, with
dependencies included and build caches excluded; it requires GNU tar.

See [DESIGN.md](DESIGN.md), the completed
[stream plan](docs/plans/2026-11-09-stream-runtime.md), the
[follow-up plan](docs/plans/2026-11-09-followups.md), and the
[qualification report](docs/validation-2026-11-09.md) for contracts and checks
actually executed. Comparative measurements use pinned jq and jaq binaries;
jaq was acquired separately because it was absent from the initial inventory.
