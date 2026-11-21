# Receipt queries in jqz

Reviewed on November 21, 2026, against jqz 0.36.0 (`a809936`). Implement
structured assertions first and strict string concatenation second. The
examples below specify the proposed syntax. Local bindings are deferred.

The `z_llvm` audit `fixed-input-quoted-scan-freezer-audit-02` exposed three
costs. Its file verifier reduces all comparisons to one boolean. Its shell
driver assembles expected executable and log paths for 50 command records.
Its manifest comparisons use `.` for a receipt entry and `root()` for an
inventory indexed by path. The existing manifest examples provide a portable
fixture for the same join. [Manifest comparisons](../../examples/cleanup/README.md)

## 1. Report the first failed assertion

Add a scalar `assert(predicate, detail)`. Require a boolean predicate.
On success return `true` and skip evaluation of `detail`. On failure evaluate
the detail object once, in the same scope, and stop at the first failure.
This lets a query author identify the file and the comparison that failed.

```text
all($receipt[0].files,
  assert(exists(root()[.path]?), {reason: "missing_file", path})
  and assert(root()[.path].bytes == .bytes, {
    reason: "size_mismatch", path, expected: .bytes, observed: root()[.path].bytes
  }))
```

Feed this expression the inventory produced by `index_by(.path)`. With a
receipt that lists `result.json` as 12 bytes and an inventory that reports 13,
one CLI invocation writes exactly one compact JSON object and a newline to
stderr and exits 1. jqz owns the outer keys and the query supplies `detail`.

```json
{"kind":"assertion_failed","detail":{"reason":"size_mismatch","path":"result.json","expected":12,"observed":13}}
```

Cap the compact, escaped UTF-8 serialization of the detail object at 4,096
bytes. Enforce the cap while serializing. For an oversized object emit
`{"kind":"assertion_failed","truncated":true}` and exit 1. This bounds the
diagnostic retained after evaluating the detail expression. A user field
called `truncated` belongs inside `detail`. CLI output-format flags apply
only to stdout. The failing assertion emits nothing there, and already
emitted NDJSON results remain available.

| Condition | CLI result |
| --- | --- |
| Reached false assertion with valid object detail | Exit 1 with or without `-e` |
| Predicate or detail has a type or evaluation error, consumed input is malformed, allocation or I/O fails | Exit 2 through the existing error path |
| Ordinary query with `-e` | Exit 1 when the last output is false or null, 4 for no output, otherwise 0 |

Give library callers a distinct assertion error. Keep the first diagnostic
in caller-owned storage through input release, stream teardown and return
from `Program.run`. A subsequent `feed` or `finish` on the failed stream must
preserve it until the caller explicitly reuses the diagnostic. Include source
location in the API when known. Aggregated and slurped values may have no
unique source location. [Library entry points](../../src/root.zig) · [CLI error handling](../../src/main.zig)

**Acceptance.** Use a two-file inventory. Check success, an absent entry, a
size mismatch, and an equal-size digest mismatch. Give two receipt rows bad
sizes above `2^53` and reverse the inventory order. Require the first bad
row in receipt order with exact integers. Check lazy detail evaluation on
success and short-circuited branches. Test failure during `finish` after
`index_by`, earlier NDJSON output, and diagnostic lifetime after stream
failure and teardown. Exercise escaped details of exactly 4,096 and 4,097
bytes. Check exit code and both output streams. A duplicate inventory key
must still produce its located evaluation error. [Diagnostics](../../src/diagnostic.zig)

Qualify these semantics at the jqz CLI and library entry points. The
`z_llvm` publisher currently appends a prose message and maps verifier errors
to exit 1. When that project adopts the feature, its adoption check
should distinguish a size mismatch from a duplicate inventory key.

## 2. Construct strings explicitly

Add `concat(array)` for an array of strings. For example,
`concat([$stage, "/commands/", .name, ".stderr"])` constructs the expected
log path from a case name. Evaluate the array once and concatenate its
UTF-8 bytes in order. Return `""` for an empty array. A non-string element
is a type error at that element. Keep `+` as checked integer arithmetic.

**Acceptance.** The original audit launches jqz four times per case for
50 cases. Supply a portable pair of arrays with the same fields. Cases
carry `name` and expected `exit`. Commands carry `cwd`, `argv`, `returncode`,
`stdout` and `stderr`. In one invocation, verify each command's argv equals
`["/bin/bash", concat([.cwd, "/freeze.sh"])]` and compare the two ordered
projections of exit code, stdout path and stderr path. Compare the result
with literal expectations. Swap two distinct command rows and require
failure. Also reject a dropped row, wrong executable and wrong log path.

Include empty strings, Unicode, quotes, backslashes, and null or numeric
elements. Check total UTF-8 byte length before allocating. The result limit
is 64 MiB per string, independent of retained and slurp budgets. Exercise
the boundary and one byte over it with a reduced test limit, and check that
allocation failures propagate.

## Deferred proposal for local bindings

The motivating example gave `root()` the name `$inventory`. The existing
join already builds its index once. Revisit `let($name, value, body)` when a
real query benefits from binding a matched row once for several comparisons,
or when a nested join needs an intermediate row. Bring that query and its
current equivalent to design review before adding syntax or scope rules.
[Existing index and scope semantics](../../DESIGN.md)

## Delivery

Keep fixtures small enough to ship in this repository. For each feature,
exercise the public library and the CLI, document the syntax and observable
behavior, and run the native x86_64 Linux Debug build and tests. Follow the
repository's versioning and commit workflow for each verified feature.
Report both commits, package versions, and results for the damaged-receipt
and swapped-command fixtures. [Project workflow](../../AGENTS.md)
