# Cleanup workflow qualification

The [cleanup workflow plan](../plans/2026-11-12-cleanup-workflow-improvements.md)
is complete at jqz 0.33.0. The implementation fixes shared shell output, adds
independent retention/slurp controls, accumulates grouped counts and integer
sums, and compares manifests through an owned index. All checks here use
native x86_64 Linux Debug with Zig 0.17.0.

## Delivered slices

| Commit | Version | Change |
| --- | --- | --- |
| `18afa4c` | 0.30.1 | Preserve inherited stdout/stderr positions |
| `28246a6` | 0.31.0 | Expose retained/slurp budgets and actionable failures |
| `f742990` | 0.32.0 | Add `count_by(key)` and `sum_by(key,value)` |
| `5ad37c8` | 0.33.0 | Add `index_by(key)`, computed object lookup and `root()` |

The final implementation snapshot is
`5ad37c84411da5f67f61e481e2a6c6fcb7edd564`. Each code slice was verified before
committing, with its version updated by the pinned package-version tool.

## Functional checks

Native build and all 273 project checks pass: 176 language/library, 61 CLI,
three binding-input, four version-workflow, three qualification-runner,
eighteen profiler and eight distribution-verifier checks. The separate
public-API consumer passes ten checks.

Descriptor regressions cover a prewritten prefix, sequential output of different
lengths, pipes and append redirection for JSON/raw/joined output, help/version
and diagnostics. Failed writes retain exit-status precedence. Independently,
the original shared-shell reproduction now produces exactly `111\n222\n`.

Portable manifest checks distinguish input text admission from owned slurp
storage, exercise independent and zero limits, reject invalid/overflow options
before input work, and preserve allocator exhaustion as `OutOfMemory`. Budget
diagnostics retain the limit, live capacity and rejected request after cleanup.

Grouped totals match materialized queries while preserving first-seen key
order and checked integer values. Index tests cover empty input, duplicate
decoded keys, Unicode, missing/null/false, source-buffer reuse, exact large
integers, nested `root()` scope, depth, budgets, early stopping, failed writes
and allocation-failure cleanup. All five
[manifest examples](../../examples/cleanup/README.md) pass: left match, inner
match, changed records, removed paths and added paths. Changes preserve left
order and detect hash-only changes and size-only changes above 2^53.

At 0.31.0, the optional 29,723,599-byte private audit passed ordinary input
with `length(.) = 15`. Default slurping failed with a 67,108,864-byte limit,
46,981,016 bytes retained and a 29,209,288-byte request. Setting
`--max-slurp-bytes 268435456` succeeded with `length(.[0]) = 15`.
The file was read only; its SHA-256 stayed
`2f9f150d6c8a4a1c93474194a7c5fe0157eaa8549c9836392ed49454c183beee`.
The plan records its location. Portable checks do not depend on that file.

## Allocation evidence

The [0.33.0 study](2026-11-12-cleanup-workflows.json) records source hashes,
retained capacity after record feeds, transient peaks and cleanup. Its SHA-256
is `a48502bf49da97b90df11e93db0ee997315a3daa7351dd9011d0f7a6b10afb19`.

| Workload | Retained bytes | Result |
| --- | ---: | --- |
| Four keys; 32 or 4,096 records; 16 or 4,096-byte payloads | 1,672 | All four cases stay flat after the distinct keys arrive |
| 64 keys; 4,096 records; 16-byte payloads | 33,050 | Retention grows with distinct keys |
| Index of 16 records; 256 repeated left keys | 9,948 | 512 successful lookups, zero lookup allocations |
| Index of 4,096 records; 65,536 repeated left keys | 2,175,024 | 131,072 successful lookups, zero lookup allocations |

The grouped comparison disables in-place resize/remap through the existing
failing-allocator helper while allowing allocations to succeed. This controls
backing-allocator placement when comparing arena capacity. The earlier
[0.32.0 evidence](2026-11-12-grouped-totals.json) remains unchanged: ordinary
allocator growth retained 908 bytes for four keys and 21,348 for 64 keys.
After later layout changes, ordinary four-key runs used 908 or 1,672 bytes;
each run still stayed flat after its keys arrived. These snapshots use
different measurement methods and do not establish a memory regression.

The index workload verifies that the object's hash index exists before
completion, then repeatedly resolves its last inserted key and checks exact
record identity/value. Lookup and completion request no allocation. All
results are checked independently, retained owner deltas match budget use,
and cleanup leaves zero live bytes. Source text, compiled programs and fixed
output buffers are excluded; transient parsing is measured separately.
These are requested allocation capacities, not RSS or timing measurements.

## Unchanged corpus

The [generated corpus report](2026-11-12-cleanup-corpus.json) records jqz
0.33.0 versus installed jq 1.7. Its SHA-256 is
`e56fc6d736d80617a1097fa15fd12c0a2094f46ec44d919a64eaf6fc73817348`.
All 45 cases pass: 30 observed translations, three supported components,
ten intentional semantic/exit probes and two generated scale cases. No
observed case is unsupported or requires an invocation adaptation.

The case manifest and provenance are byte-unchanged from request commit
`e7d2fbf`. All recorded source hashes match the implementation snapshot.
One repetition covers 35 equivalent cases with 70 samples. This establishes
functional compatibility for the selected sample; it does not measure the
new cleanup workloads or establish a general jq replacement rate or speedup.
The focused checks and allocation study above qualify the new workflows
separately. Earlier repeated performance and standalone archive evidence
remain historical checkpoints, as listed in the [index](README.md).

## Reproduce and limits

From the project root:

```sh
zig build
zig build test
(cd tests/package && zig build test)
mkdir -p zig-out/qualification
zig build study-cleanup > zig-out/qualification/local-cleanup-workflows.json
zig build qualify -- --repeat 1 --out zig-out/qualification/local-cleanup-corpus.json
```

The [manifest examples](../../examples/cleanup/README.md) include runnable
commands and fixtures. The study uses Zig and the existing allocation helpers;
corpus replay uses installed jq and GNU time. No additional tool is required.

Grouped totals search distinct keys linearly: O(records × distinct keys), with
retention proportional to distinct keys and fixed accumulators. `index_by`
owns complete records under the retained budget; computed lookup accepts string
object keys, and literal array access keeps its existing rules. Scalar temporaries, input
parsing and bindings have separate limits/lifetimes, so the two CLI budgets
do not bound process RSS. There is no general reducer or disk spill.
