# Receipt queries in jqz

Proposed on November 21, 2026, against jqz 0.36.0 (`a809936`). The examples
below use proposed syntax. Implement the three changes in order, starting with
the one that helps a developer diagnose a failed receipt in a single invocation.

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
one CLI invocation should write this detail to stderr and exit 1.

```json
{"reason":"size_mismatch","path":"result.json","expected":12,"observed":13}
```

Give library callers a distinct assertion failure and access to bounded,
owned diagnostic detail after evaluation unwinds. For an oversized detail,
emit a small valid JSON object marking truncation. Document the byte limit.
An explicit failed assertion exits 1 with or without `-e`. Malformed input,
a non-boolean predicate, or a detail that fails to produce an object exits 2. Keep
the existing `-e` behavior for ordinary queries, including exit 4 for no
output. Earlier NDJSON records may already have reached stdout.

**Acceptance.** Use a two-file inventory. Check success, an absent entry, a
size mismatch, and an equal-size digest mismatch. Assert the first offending
path, exact values, exit status and stdout/stderr separately. Include an
integer above `2^53`, a failing detail expression skipped on success, and a
detail large enough to exercise truncation. Reuse the existing diagnostic
location machinery where the source path is known. [Diagnostics](../../src/diagnostic.zig)

## 2. Construct strings explicitly

Add `concat(array)` for an array of strings. For example,
`concat([$stage, "/commands/", .name, ".stderr"])` constructs the expected
log path for a command record. Evaluate the array once and concatenate its
UTF-8 bytes in order. Return `""` for an empty array. A non-string element
is a type error at that element. Keep `+` as checked integer arithmetic.

**Acceptance.** Compare the constructed executable, stdout and stderr paths
with literal expectations on a portable command-record fixture. Include
empty strings, Unicode, quotes, backslashes, and a null or numeric element.
Check the total byte length before allocating. The proposed result limit is
64 MiB per string. Exercise the boundary and one byte over it with a reduced
test limit, and check that allocation failures propagate.

## 3. Give computed values local names

Add an immutable expression binding. The proposed form is
`let($name, value, body)`. Evaluate `value` once in the caller's scope and
make the name available throughout `body`, including nested array predicates.
Keep the current item and the meaning of `root()` at each existing stage.

```text
$inventory_rows[0] | each | index_by(.path)
| let($inventory, ., all($receipt[0].files,
    exists($inventory[.path]?)
    and $inventory[.path].bytes == .bytes
    and $inventory[.path].sha256 == .sha256))
```

**Acceptance.** Compare this query with its `root()` equivalent on matching,
missing, and changed files. Test nested bindings with distinct names, access
outside the body, and conflicts with an active local or external binding.
Reject ambiguous names at compile time. Reuse the index across the predicate
calls and verify its lifetime with successive NDJSON inputs and a downstream
retaining stage. [Existing index and scope semantics](../../DESIGN.md)

## Delivery

Keep fixtures small enough to ship in this repository. For each feature,
exercise the public library and the CLI, document the syntax and observable
behavior, and run the native x86_64 Linux Debug build and tests. Follow the
repository's versioning and commit workflow for each verified feature.
The first delivery is complete when a developer can identify a damaged
receipt entry directly from the failed invocation. [Project workflow](../../AGENTS.md)
